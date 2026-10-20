# shellcheck shell=bash
# Health checks, journal capture, screenshots and key input.

# Print "Key: value" health lines; return 1 if anything is unhealthy.
# Usage: check_health <pre_pid> <since>
check_health() {
    local pre_pid="$1" since="$2" status=0 post_pid state errors

    post_pid=$(shell_pid)
    if [[ -n "$post_pid" ]]; then
        echo "GNOME Shell: running"
    else
        echo "GNOME Shell: NOT RUNNING"
        status=1
    fi

    if [[ -n "$pre_pid" ]]; then
        if [[ -z "$post_pid" ]]; then
            log_error "GNOME Shell is not running (may have crashed fatally)"
            echo "Crash: GNOME Shell restarted"
            status=1
        elif [[ "$pre_pid" != "$post_pid" ]]; then
            log_warn "GNOME Shell PID changed: $pre_pid -> $post_pid (crash + restart detected)"
            echo "Crash: GNOME Shell restarted"
            status=1
        else
            echo "Crash: none detected"
        fi
    fi

    state=$(ext_state)
    if state_is_active "$state"; then
        echo "Extension: ACTIVE"
    else
        echo "Extension: ${state:-State: UNKNOWN}"
        status=1
    fi

    errors=$(js_errors "$since")
    if [[ -z "$errors" ]]; then
        echo "JS Errors: none"
    else
        log_error "JS errors found:"
        echo "$errors" >&2
        echo "JS Errors: FOUND (see logs)"
        status=1
    fi
    return $status
}

# The extension's "State: ..." line, or nothing if the Shell can't say.
ext_state() {
    vm_ssh "gnome-extensions show $EXT_UUID 2>/dev/null | grep State:" 2>/dev/null | sed 's/^[[:space:]]*//' || true
}

# GNOME 45 calls a running extension ENABLED; 46 and later call it ACTIVE
# (and have an INACTIVE, so match the whole word).
state_is_active() { grep -qE '^State: (ACTIVE|ENABLED)$' <<< "$1"; }

# Poll until the extension is running. Usage: wait_ext_active <timeout_secs>
wait_ext_active() {
    local timeout="$1" elapsed=0
    while (( elapsed < timeout )); do
        state_is_active "$(ext_state)" && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# JS errors that mention the project's LOG_FILTER, since a guest time.
js_errors() {
    vm_ssh "journalctl --user -b --since='$1' --no-pager 2>/dev/null | grep -i 'JS ERROR' | grep -iE '$LOG_FILTER' || true" 2>/dev/null
}

# Write the Shell journal, extension state and Shell version to a file.
# Usage: capture_logs <file> <since>
capture_logs() {
    local file="$1" since="$2"
    mkdir -p "$(dirname "$file")"
    vm_ssh "
        echo '=== GNOME Shell Journal Logs ==='
        journalctl --user -b --since='$since' --no-pager 2>/dev/null \
            | grep -iE 'gnome-shell|$LOG_FILTER|extension|JS ERROR|gjs' || true
        echo ''
        echo '=== Extension State ==='
        gnome-extensions show $EXT_UUID 2>/dev/null || echo 'Extension not found'
        echo ''
        echo '=== GNOME Shell Version ==='
        gnome-shell --version 2>/dev/null || echo 'unknown'
    " > "$file" 2>/dev/null || true
    if [[ -s "$file" ]]; then
        gev_event logs path="$file"
        log_ok "Logs saved: $file"
        echo "$file"
    else
        log_error "Log capture failed"
        return 1
    fi
}

# virsh screenshot -> PNG. Usage: take_screenshot <png_path>
take_screenshot() {
    local png="$1" ppm="${1%.png}.ppm"
    mkdir -p "$(dirname "$png")"
    vm_is_running || { log_error "Cannot screenshot: VM '$VM_NAME' is not running"; return 1; }
    "${VIRSH[@]}" screenshot "$VM_DOMAIN" --file "$ppm" &>/dev/null
    [[ -f "$ppm" ]] || { log_error "virsh screenshot failed: no file produced"; return 1; }
    magick "$ppm" "$png" 2>/dev/null
    rm -f "$ppm"
    [[ -f "$png" ]] || { log_error "Image conversion failed"; return 1; }
    gev_event screenshot path="$png"
    log_ok "Screenshot saved: $png"
    echo "$png"
}

# Where a named screenshot goes: the run's shots/ dir during a run, else a
# timestamped file in the results dir.
screenshot_path() {
    local name="${1:-screenshot}"
    if [[ -n "${GEV_RUN_DIR:-}" ]]; then
        echo "$GEV_RUN_DIR/shots/$name.png"
    else
        echo "$RESULTS_DIR/${VM_NAME}_${name}_$(date +%Y%m%d-%H%M%S).png"
    fi
}

# Map friendly key names to the Linux keycode names virsh send-key takes.
# Anything already spelled KEY_* passes through.
key_name() {
    local k="$1" up
    up=$(tr '[:lower:]' '[:upper:]' <<< "$k")
    case "$up" in
        KEY_*) echo "$up" ;;
        SHIFT) echo KEY_LEFTSHIFT ;;
        CTRL|CONTROL) echo KEY_LEFTCTRL ;;
        ALT) echo KEY_LEFTALT ;;
        SUPER|META|WIN) echo KEY_LEFTMETA ;;
        PRINT|PRINTSCREEN|PRTSC|SYSRQ) echo KEY_SYSRQ ;;
        ENTER|RETURN) echo KEY_ENTER ;;
        ESC|ESCAPE) echo KEY_ESC ;;
        SPACE) echo KEY_SPACE ;;
        TAB) echo KEY_TAB ;;
        BACKSPACE) echo KEY_BACKSPACE ;;
        DELETE|DEL) echo KEY_DELETE ;;
        UP|DOWN|LEFT|RIGHT|HOME|END|PAGEUP|PAGEDOWN|F[0-9]|F1[0-2]) echo "KEY_$up" ;;
        [A-Z0-9]) echo "KEY_$up" ;;
        *) return 1 ;;
    esac
}

# Press a chord: send_keys [hold_ms] Shift+Print
send_keys() {
    local hold="$1" chord="$2" part k parts keys=()
    IFS='+' read -ra parts <<< "$chord"
    for part in "${parts[@]}"; do
        k=$(key_name "$part") || { log_error "Unknown key '$part' in '$chord'"; return 1; }
        keys+=("$k")
    done
    gev_event send_key keys="$chord"
    "${VIRSH[@]}" send-key "$VM_DOMAIN" --codeset linux --holdtime "$hold" "${keys[@]}" >/dev/null
    log_ok "Sent $chord to '$VM_NAME'"
}

# Guest screen size as "W H", read from a screendump (PNG or PPM, by QEMU
# version).
screen_size() {
    local tmp size
    tmp=$(mktemp)
    "${VIRSH[@]}" screenshot "$VM_DOMAIN" --file "$tmp" &>/dev/null
    size=$(magick identify -format '%w %h' "$tmp" 2>/dev/null) || true
    rm -f "$tmp"
    [[ "$size" =~ ^[0-9]+\ [0-9]+$ ]] \
        || { log_error "Cannot read screen size of '$VM_NAME'"; return 1; }
    echo "$size"
}

# Send QMP input events. The VM's absolute pointer is its USB tablet, so
# coordinates are 0..32767 across the screen, not pixels.
qmp_input() {
    local out
    out=$("${VIRSH[@]}" qemu-monitor-command "$VM_DOMAIN" \
        "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[$1]}}" 2>&1)
    [[ "$out" == *'"return"'* ]] || { log_error "QMP input failed: $out"; return 1; }
}

# Move the pointer to screen pixel X Y.
pointer_move() {
    local x="$1" y="$2" w h
    [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] \
        || { log_error "pointer: X and Y must be pixel integers"; return 1; }
    read -r w h < <(screen_size) || return 1
    (( x < w && y < h )) \
        || { log_error "pointer: $x,$y is off the ${w}x$h screen"; return 1; }
    gev_event pointer action=move x="$x" y="$y"
    qmp_input "{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$(( x * 32767 / (w - 1) ))}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$(( y * 32767 / (h - 1) ))}}"
}

# Press and release a button where the pointer is: left, right or middle.
pointer_click() {
    local button="$1" ev
    case "$button" in
        left|right|middle) ;;
        *) log_error "pointer: unknown button '$button'"; return 1 ;;
    esac
    ev="{\"type\":\"btn\",\"data\":{\"button\":\"$button\",\"down\""
    gev_event pointer action=click button="$button"
    qmp_input "$ev:true}}" || return 1
    sleep 0.05
    qmp_input "$ev:false}}"
}
