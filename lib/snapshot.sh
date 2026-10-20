# shellcheck shell=bash
# Live snapshots (memory included, so a restore lands on a running desktop),
# and the per-project package layers built on top of the base snapshot.

snapshot_exists() {
    "${VIRSH[@]}" snapshot-list "$VM_DOMAIN" --name 2>/dev/null | grep -qx "${1:-$SNAPSHOT_NAME}"
}

# Usage: snapshot_create <name> <description>
snapshot_create() {
    local snap="$1" description="$2"
    vm_is_running || { log_error "VM '$VM_NAME' must be running to take a live snapshot"; return 1; }
    if snapshot_exists "$snap"; then
        log_info "Deleting existing snapshot '$snap'..."
        "${VIRSH[@]}" snapshot-delete "$VM_DOMAIN" "$snap" &>/dev/null || true
    fi
    log_info "Creating snapshot '$snap' for VM '$VM_NAME'..."
    "${VIRSH[@]}" snapshot-create-as "$VM_DOMAIN" "$snap" --description "$description" --atomic >/dev/null
    log_ok "Snapshot '$snap' created"
}

# Restore a snapshot, then step the guest clock to the host's: a live
# snapshot brings back the clock it was taken with, and journalctl --since,
# TLS and the panel clock all read it.
snapshot_restore() {
    local snap="${1:-$SNAPSHOT_NAME}"
    snapshot_exists "$snap" || { log_error "Snapshot '$snap' not found for VM '$VM_NAME'"; return 1; }
    log_info "Restoring VM '$VM_NAME' to snapshot '$snap'..."
    gev_event restore_start snapshot="$snap"
    "${VIRSH[@]}" snapshot-revert "$VM_DOMAIN" "$snap"
    vm_is_running || "${VIRSH[@]}" start "$VM_DOMAIN" >/dev/null
    vm_ssh "sudo date -u -s @$(date +%s) >/dev/null" 2>/dev/null \
        || log_warn "Could not sync the guest clock (SSH not up yet?)"
    gev_event restore_end snapshot="$snap"
    log_ok "Snapshot '$snap' restored"
}

snapshot_created_at() {
    "${VIRSH[@]}" snapshot-dumpxml "$VM_DOMAIN" "$1" 2>/dev/null \
        | sed -n 's:.*<creationTime>\(.*\)</creationTime>.*:\1:p'
}

# Print the snapshot a test should restore for this project on this VM.
#
# With no extra guest packages that is the base snapshot. Otherwise it is a
# layer: base + the packages, snapshotted live. The layer's key hashes the
# package list and the base snapshot's creation time, so changing either
# builds a new layer. If the base already has every package, the layer is
# the base itself and no snapshot is added.
layer_snapshot() {
    local pkgs key marker snap
    pkgs=$(config_packages | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
    pkgs="${pkgs% }"
    if [[ -z "$pkgs" ]]; then
        echo "$SNAPSHOT_NAME"
        return
    fi
    key=$(printf '%s|%s' "$pkgs" "$(snapshot_created_at "$SNAPSHOT_NAME")" | sha1sum | cut -c1-10)
    marker="$GEV_LAYERS/$VM_DOMAIN.$key"
    if [[ -f "$marker" ]]; then
        snap=$(cat "$marker")
        if snapshot_exists "$snap"; then
            echo "$snap"
            return
        fi
    fi
    layer_build "$pkgs" "$key" "$marker" || return 1
    cat "$marker"
}

layer_build() {
    local pkgs="$1" key="$2" marker="$3" check install snap
    log_info "Building package layer for '$VM_NAME': $pkgs"
    gev_event layer_build_start packages="$pkgs" key="$key"
    snapshot_restore "$SNAPSHOT_NAME" >&2 || return 1
    vm_wait_ssh 120 >&2 || return 1
    # shellcheck disable=SC2086  # word-splitting the package list is intended
    case "$(vm_family)" in
        fedora)
            check="rpm -q $pkgs >/dev/null"
            install="sudo dnf install -y $pkgs 2>&1 | tail -5" ;;
        debian)
            check="dpkg -s $pkgs >/dev/null 2>&1"
            install="sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs 2>&1 | tail -5" ;;
        *) log_error "Don't know how to install packages on '$VM_OS_VARIANT'"; return 1 ;;
    esac
    if vm_ssh "$check" 2>/dev/null; then
        log_ok "Base snapshot already has every package; the layer is the base"
        echo "$SNAPSHOT_NAME" > "$marker"
    else
        vm_ssh "$install" >&2 || { log_error "Package install failed"; return 1; }
        vm_ssh "$check" 2>/dev/null || { log_error "Packages still missing after install: $pkgs"; return 1; }
        vm_wait_shell 60 >&2 || return 1
        snap="gev-layer-$key"
        snapshot_create "$snap" "Base + packages: $pkgs" >&2 || return 1
        echo "$snap" > "$marker"
    fi
    gev_event layer_build_end snapshot="$(cat "$marker")"
}
