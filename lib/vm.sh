# shellcheck shell=bash
# VM lifecycle: create from a cloud image, provision GNOME, adopt an
# existing domain, destroy.

# Create the VM currently loaded by vm_resolve. Usage: vm_create [force]
vm_create() {
    local force="${1:-false}" image cached disk seed port
    ensure_ssh_key

    if [[ -n "$VM_DOMAIN" ]] && vm_exists; then
        if ! $force; then
            log_warn "VM '$VM_NAME' already exists (domain $VM_DOMAIN). Use --force to recreate."
            return 0
        fi
        log_warn "VM '$VM_NAME' exists, destroying (--force)..."
        vm_destroy
    fi

    VM_DOMAIN="${GEV_DOMAIN_PREFIX}${VM_NAME}"
    if vm_exists; then
        die "Domain '$VM_DOMAIN' already exists in libvirt but is not registered. Adopt it (gnome-ext-vm adopt) or remove it."
    fi

    # Step 1: cloud image, downloaded once and shared by every VM made from it.
    image=$(basename "$VM_IMAGE_URL")
    cached="$GEV_IMAGES/$image"
    if [[ -f "$cached" ]]; then
        log_ok "Cloud image already cached: $cached"
    else
        log_info "Downloading cloud image: $VM_IMAGE_URL"
        curl -fL --progress-bar -o "$cached.tmp" "$VM_IMAGE_URL"
        mv "$cached.tmp" "$cached"
        log_ok "Cloud image downloaded: $cached"
    fi

    # Step 2: copy-on-write disk backed by the cached image.
    disk="$GEV_DISKS/${VM_DOMAIN}.qcow2"
    log_info "Creating CoW disk (${VM_DISK_GB}GB) backed by the cloud image..."
    qemu-img create -q -f qcow2 -b "$cached" -F qcow2 "$disk" "${VM_DISK_GB}G"

    # Step 3: cloud-init seed.
    seed="$GEV_DISKS/${VM_DOMAIN}-seed.iso"
    make_seed_iso "$seed" "${GEV_KEY}.pub"

    # Step 4: define and boot, with SSH forwarded from a free host port.
    port=$(alloc_port)
    VM_SSH_PORT="$port" VM_SSH_KEY="$GEV_KEY"
    registry_add "$VM_NAME" "$VM_DOMAIN" "$VM_SSH_PORT" "$VM_SSH_KEY"
    log_info "Creating VM with virt-install (qemu:///session)..."
    virt-install \
        --connect qemu:///session \
        --name "$VM_DOMAIN" \
        --os-variant "$VM_OS_VARIANT" \
        --vcpus "$VM_VCPUS" \
        --memory "$VM_RAM_MB" \
        --disk "path=$disk,format=qcow2" \
        --disk "path=$seed,device=cdrom" \
        --network "user,model=virtio,backend.type=passt,portForward0.proto=tcp,portForward0.range0.start=${VM_SSH_PORT},portForward0.range0.to=22" \
        --graphics spice,gl.enable=no,listens0.type=socket \
        --video virtio \
        --noautoconsole \
        --import
    log_ok "VM booting (SSH forwarded to localhost:$VM_SSH_PORT)"

    # Step 5: cloud-init.
    vm_wait_ssh 300 || return 1
    log_info "Waiting for cloud-init to finish..."
    local elapsed=0
    until vm_ssh "test -f /var/lib/cloud/instance/boot-finished" 2>/dev/null; do
        if (( elapsed >= 300 )); then
            log_warn "cloud-init may not have finished; proceeding anyway"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done

    # Step 6: GNOME desktop, auto-login, no lock screen.
    vm_provision || return 1

    # Step 7: the base snapshot every test restores.
    snapshot_create "$SNAPSHOT_NAME" "Clean GNOME session for $VM_NAME (GNOME $VM_GNOME_VERSION)"

    # Shut down so creating several VMs in a row does not stack their RAM.
    vm_shutdown_wait
    log_ok "VM '$VM_NAME' is ready (GNOME $VM_GNOME_VERSION, ssh port $VM_SSH_PORT)"
}

vm_shutdown_wait() {
    log_info "Shutting down VM '$VM_NAME'..."
    vm_shutdown
    local _i
    for _i in $(seq 1 15); do
        vm_is_running || break
        sleep 2
    done
    vm_is_running && "${VIRSH[@]}" destroy "$VM_DOMAIN" &>/dev/null
    log_ok "VM '$VM_NAME' shut down"
}

make_seed_iso() {
    local out="$1" pubkey_file="$2" tmp
    tmp=$(mktemp -d)
    awk -v key="$(cat "$pubkey_file")" '{gsub(/SSH_PUBKEY_PLACEHOLDER/, key); print}' \
        "$GEV_ROOT/cloud-init/user-data.yaml" > "$tmp/user-data"
    cp "$GEV_ROOT/cloud-init/meta-data.yaml" "$tmp/meta-data"
    genisoimage -output "$out" -volid cidata -joliet -rock -quiet \
        "$tmp/user-data" "$tmp/meta-data"
    rm -rf "$tmp"
    log_ok "Seed ISO created: $out"
}

# Install a GNOME desktop with GDM auto-login, reboot into it, and turn off
# the lock screen and idle blanking. Project packages are not installed
# here; they go in per-project layers (see layer_snapshot).
vm_provision() {
    local distro gdm_conf gdm_unit custom
    distro=$(vm_ssh "source /etc/os-release && echo \$ID")
    log_info "Provisioning '$VM_NAME' (distro: $distro)..."
    case "$distro" in
        fedora)
            log_info "Installing GNOME desktop (this takes several minutes)..."
            vm_ssh "sudo dnf install -y @gnome-desktop gnome-extensions-app gnome-shell-extension-common glib2-devel 2>&1 | tail -5"
            gdm_conf=/etc/gdm gdm_unit=gdm ;;
        debian|ubuntu)
            log_info "Installing GNOME desktop..."
            vm_ssh "sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gnome-session gnome-shell gdm3 gnome-shell-extension-prefs glib-networking 2>&1 | tail -5"
            gdm_conf=/etc/gdm3 gdm_unit=gdm3 ;;
        *) log_error "Unsupported distro: $distro"; return 1 ;;
    esac

    custom='[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=testuser\nWaylandEnable=true\n\n[security]\n\n[xdmcp]\n\n[chooser]\n\n[debug]\n'
    vm_ssh "sudo mkdir -p $gdm_conf && printf '$custom' | sudo tee $gdm_conf/custom.conf > /dev/null"
    vm_ssh "sudo systemctl set-default graphical.target && sudo systemctl enable $gdm_unit"

    log_info "Rebooting into the graphical session..."
    vm_ssh "sudo reboot" || true
    sleep 10
    vm_wait_ssh 300 || return 1
    vm_wait_shell 120 || return 1
    sleep 10

    vm_ssh "gsettings set org.gnome.desktop.session idle-delay 0; gsettings set org.gnome.desktop.screensaver lock-enabled false; gsettings set org.gnome.desktop.notifications show-banners false; gsettings set org.gnome.desktop.screensaver idle-activation-enabled false" 2>/dev/null || true
    log_ok "Provisioned: $(vm_ssh 'gnome-shell --version' 2>/dev/null || echo 'GNOME Shell version unknown')"
}

# The SSH forward's host port, read from the domain XML.
domain_ssh_port() {
    "${VIRSH[@]}" dumpxml "$1" 2>/dev/null | tr -d '\n' \
        | grep -o '<portForward[^>]*proto=.tcp.[^>]*>[[:space:]]*<range[^>]*to=.22.[^>]*/>' \
        | grep -o "start=.[0-9]*" | grep -o '[0-9]*' | head -1
}

# Register an existing libvirt domain as VM_NAME. Nothing about the domain
# changes: its disks, snapshots and authorized key stay where they are.
# Usage: vm_adopt <domain> <ssh_key>
vm_adopt() {
    local domain="$1" key="$2" port disk backing
    "${VIRSH[@]}" dominfo "$domain" &>/dev/null || { log_error "No such domain: $domain"; return 1; }
    [[ -f "$key" ]] || { log_error "SSH key not found: $key"; return 1; }
    port=$(domain_ssh_port "$domain")
    [[ -n "$port" ]] || { log_error "Could not find an SSH port forward in $domain's XML"; return 1; }
    VM_DOMAIN="$domain"
    snapshot_exists || log_warn "Domain '$domain' has no '$SNAPSHOT_NAME' snapshot; tests will run on its current state"
    registry_add "$VM_NAME" "$domain" "$port" "$(realpath "$key")"
    log_ok "Adopted '$domain' as '$VM_NAME' (ssh port $port)"

    # Hard-link its base image into the shared cache, so a later create of
    # the same image skips the download. The domain keeps using the original
    # path, which stays put.
    disk=$("${VIRSH[@]}" domblklist "$domain" --details 2>/dev/null | awk '$2 == "disk" {print $4; exit}')
    backing=$(qemu-img info -U "$disk" 2>/dev/null | sed -n 's/^backing file: \(.*\)$/\1/p' | sed 's/ (actual path.*//')
    if [[ -n "$backing" && -f "$backing" && ! -e "$GEV_IMAGES/$(basename "$backing")" ]]; then
        ensure_dirs
        ln "$backing" "$GEV_IMAGES/$(basename "$backing")" 2>/dev/null \
            && log_ok "Linked base image into cache: $(basename "$backing")"
    fi
}

vm_destroy() {
    log_info "Destroying VM '$VM_NAME' (domain $VM_DOMAIN)..."
    vm_is_running && "${VIRSH[@]}" destroy "$VM_DOMAIN" &>/dev/null
    "${VIRSH[@]}" undefine "$VM_DOMAIN" --remove-all-storage --snapshots-metadata &>/dev/null || true
    rm -f "$GEV_DISKS/${VM_DOMAIN}-seed.iso" "$GEV_LAYERS/$VM_DOMAIN".*
    registry_remove "$VM_NAME"
    log_ok "VM '$VM_NAME' destroyed (cached cloud images kept in $GEV_IMAGES)"
}
