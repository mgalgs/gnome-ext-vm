# shellcheck shell=bash
# shellcheck disable=SC2153  # EXT_UUID and friends come from config.sh
# Build the extension zip on the host and install it in the VM the way a
# user would (gnome-extensions install), then enable it.

# Build the zip and print its path.
build_zip() {
    if [[ -n "$EXT_BUILD" ]]; then
        log_info "Building extension zip: $EXT_BUILD"
        (cd "$PROJECT_ROOT" && bash -c "$EXT_BUILD") 2>&1 | tail -3 >&2
        [[ ${PIPESTATUS[0]} -eq 0 ]] || { log_error "Build failed"; return 1; }
        [[ -f "$EXT_ZIP" ]] || { log_error "Zip file not found after build: $EXT_ZIP"; return 1; }
        echo "$EXT_ZIP"
        return
    fi
    local out="$RESULTS_DIR/.build"
    mkdir -p "$out"
    rm -f "$out/${EXT_UUID}.zip" "$out/${EXT_UUID}.shell-extension.zip"
    log_info "Packing $EXT_SRC_DIR"
    if command -v gnome-extensions >/dev/null; then
        local extra=() f
        # pack takes the standard files itself; everything else is extra.
        while IFS= read -r f; do
            case "$f" in
                metadata.json|extension.js|prefs.js|stylesheet.css|schemas|locale|po) ;;
                *) extra+=(--extra-source="$f") ;;
            esac
        done < <(cd "$EXT_SRC_DIR" && ls -A)
        gnome-extensions pack --force --out-dir="$out" "${extra[@]}" "$EXT_SRC_DIR" >&2 \
            || { log_error "gnome-extensions pack failed"; return 1; }
        mv "$out/${EXT_UUID}.shell-extension.zip" "$out/${EXT_UUID}.zip"
    else
        (cd "$EXT_SRC_DIR" && zip -qr "$out/${EXT_UUID}.zip" .) || return 1
    fi
    echo "$out/${EXT_UUID}.zip"
}

# Returns 0 on success, 1 on failure.
deploy_extension() {
    local zip remote="/tmp/${EXT_UUID}.zip" known
    gev_event deploy_start
    zip=$(build_zip) || return 1
    log_ok "Zip built: $zip"

    log_info "Deploying extension to VM..."
    scp "${SSH_OPTS[@]}" -i "$VM_SSH_KEY" -P "$VM_SSH_PORT" "$zip" "${SSH_USER}@localhost:$remote" \
        || { log_error "Copying the zip to the VM failed"; return 1; }
    vm_ssh "gnome-extensions install --force $remote" || { log_error "gnome-extensions install failed"; return 1; }
    log_ok "Extension installed from zip"

    # Some GNOME versions only find the extension's schemas system-wide.
    vm_ssh "sudo cp ~/.local/share/gnome-shell/extensions/$EXT_UUID/schemas/*.gschema.xml /usr/share/glib-2.0/schemas/ 2>/dev/null && sudo glib-compile-schemas /usr/share/glib-2.0/schemas/ 2>/dev/null" || true

    # A Shell that has never seen this UUID only discovers it on a new
    # session, so restart GDM and let auto-login bring one up.
    known=$(vm_ssh "gnome-extensions show $EXT_UUID 2>&1 || true")
    if grep -q "doesn't exist" <<< "$known"; then
        log_info "Extension not yet known to GNOME Shell; restarting GDM so it is discovered..."
        gev_event gdm_restart
        # The Shell creates this at startup and removes it a minute later; a
        # Shell that starts while it exists runs with extensions disabled.
        # Snapshots taken inside that minute restore it, so clear it first.
        vm_ssh "rm -f /run/user/\$(id -u)/gnome-shell-disable-extensions; sudo systemctl restart gdm 2>/dev/null || sudo systemctl restart gdm3" || true
        sleep 5
        vm_wait_shell 60 || true
        sleep 5
    fi

    log_info "Enabling extension..."
    vm_ssh "gnome-extensions enable $EXT_UUID 2>/dev/null" || true
    # Disable then enable: the Wayland-safe way to pick up new code.
    vm_ssh "gnome-extensions disable $EXT_UUID 2>/dev/null; sleep 2; gnome-extensions enable $EXT_UUID 2>/dev/null" || true
    sleep 5
    # Right after a GDM restart the Shell's Extensions service can be
    # mid-restart and answer with no state, so give it a while.
    wait_ext_active 30 || log_warn "Extension not running yet; the health check will say why"
    gev_event deploy_end
    log_ok "Extension deployed and enabled"
}
