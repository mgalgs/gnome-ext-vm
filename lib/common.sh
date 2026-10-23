# shellcheck shell=bash
# shellcheck disable=SC2034  # globals here are read by the files sourcing this one
# Shared state, logging, the VM catalog and registry, SSH helpers and the
# per-run event log. Sourced by bin/gnome-ext-vm; not meant to run alone.
#
# Uses qemu:///session (user-mode libvirt) with passt networking: no root.

# Bump with each release tag (vX.Y.Z).
GEV_VERSION="0.1.0"

GEV_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEV_ROOT="$(cd "$GEV_LIB/.." && pwd)"

# --- Shared state (one copy per user, shared by every project) ---
GEV_DATA="${GEV_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/gnome-ext-vm}"
GEV_IMAGES="$GEV_DATA/images"
GEV_DISKS="$GEV_DATA/disks"
GEV_KEY="$GEV_DATA/ssh/id_ed25519"
GEV_REGISTRY="$GEV_DATA/vms.registry"
GEV_LAYERS="$GEV_DATA/layers"
GEV_LOCKS="$GEV_DATA/locks"
GEV_CATALOGS=("$GEV_ROOT/vms.conf" "${XDG_CONFIG_HOME:-$HOME/.config}/gnome-ext-vm/vms.conf")

GEV_DOMAIN_PREFIX="gev-"
SNAPSHOT_NAME="clean-gnome-session"
VIRSH=(virsh -c qemu:///session)

SSH_USER="testuser"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR
          -o IdentitiesOnly=yes)

# --- Logging (stderr, so stdout stays clean for paths and results) ---
if [[ -t 2 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' BLUE='\033[0;34m' NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi
log_info()  { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 2; }

# ImageMagick 7 is `magick`; Debian and Ubuntu still ship 6 (`convert`,
# `identify`).
img_convert() {
    if command -v magick &>/dev/null; then magick "$1" "$2"; else convert "$1" "$2"; fi
}
img_size() {
    local id=(identify)
    command -v magick &>/dev/null && id=(magick identify)
    "${id[@]}" -format '%w %h' "$1"
}

ensure_dirs() {
    mkdir -p "$GEV_IMAGES" "$GEV_DISKS" "$(dirname "$GEV_KEY")" "$GEV_LAYERS" "$GEV_LOCKS"
}

ensure_ssh_key() {
    ensure_dirs
    if [[ ! -f "$GEV_KEY" ]]; then
        log_info "Generating SSH key pair at $GEV_KEY"
        ssh-keygen -t ed25519 -f "$GEV_KEY" -N "" -C "gnome-ext-vm" -q
    fi
}

# --- Catalog: which VMs can exist (distro, GNOME version, image) ---
# Format: name|os_variant|gnome_version|image_url|vcpus|ram_mb|disk_gb
# A later catalog file overrides an earlier one entry by entry.
catalog_lines() {
    local f
    for f in "${GEV_CATALOGS[@]}"; do
        [[ -f "$f" ]] && grep -v -e '^#' -e '^[[:space:]]*$' "$f"
    done | awk -F'|' '{ if (!($1 in seen)) order[++n] = $1; seen[$1] = $0 }
                      END { for (i = 1; i <= n; i++) print seen[order[i]] }'
}

catalog_names() { catalog_lines | cut -d'|' -f1; }

# Sets VM_NAME VM_OS_VARIANT VM_GNOME_VERSION VM_IMAGE_URL VM_VCPUS VM_RAM_MB VM_DISK_GB
catalog_load() {
    local line
    line=$(catalog_lines | grep "^$1|" || true)
    [[ -n "$line" ]] || return 1
    IFS='|' read -r VM_NAME VM_OS_VARIANT VM_GNOME_VERSION VM_IMAGE_URL \
        VM_VCPUS VM_RAM_MB VM_DISK_GB <<< "$line"
}

# fedora | debian, from the os_variant.
vm_family() {
    case "$VM_OS_VARIANT" in
        fedora*|rhel*|centos*|almalinux*|rocky*) echo fedora ;;
        ubuntu*|debian*) echo debian ;;
        *) echo unknown ;;
    esac
}

# --- Registry: which VMs do exist ---
# Format: name|domain|ssh_port|ssh_key
registry_lines() { [[ -f "$GEV_REGISTRY" ]] && grep -v '^#' "$GEV_REGISTRY" || true; }

registry_add() {
    ensure_dirs
    registry_remove "$1"
    echo "$1|$2|$3|$4" >> "$GEV_REGISTRY"
}

registry_remove() {
    [[ -f "$GEV_REGISTRY" ]] || return 0
    local tmp="$GEV_REGISTRY.tmp"
    grep -v "^$1|" "$GEV_REGISTRY" > "$tmp" || true
    mv "$tmp" "$GEV_REGISTRY"
}

registry_names() { registry_lines | cut -d'|' -f1; }

# Resolve a VM by its name, or by its libvirt domain name (so an adopted
# VM's original domain name keeps working). Sets the catalog fields plus VM_DOMAIN,
# VM_SSH_PORT and VM_SSH_KEY; VM_DOMAIN is empty when the VM is not created.
vm_resolve() {
    local want="$1" line name
    line=$(registry_lines | awk -F'|' -v w="$want" '$1 == w || $2 == w' | sed -n 1p)
    name="${line%%|*}"
    [[ -n "$line" ]] || name="$want"
    if ! catalog_load "$name"; then
        log_error "Unknown VM '$want'. Known VMs:"
        catalog_names | sed 's/^/  /' >&2
        return 1
    fi
    VM_DOMAIN="" VM_SSH_PORT="" VM_SSH_KEY=""
    if [[ -n "$line" ]]; then
        IFS='|' read -r _ VM_DOMAIN VM_SSH_PORT VM_SSH_KEY <<< "$line"
    fi
}

# Like vm_resolve, but the VM must exist.
vm_require() {
    vm_resolve "$1" || exit 2
    if [[ -z "$VM_DOMAIN" ]]; then
        die "VM '$VM_NAME' has not been created. Run: gnome-ext-vm create --vm $VM_NAME"
    fi
    vm_exists || die "VM '$VM_NAME' is registered as domain '$VM_DOMAIN', which libvirt does not know"
}

vm_exists()     { "${VIRSH[@]}" dominfo "$VM_DOMAIN" &>/dev/null; }
vm_is_running() { [[ "$("${VIRSH[@]}" domstate "$VM_DOMAIN" 2>/dev/null || true)" == "running" ]]; }

vm_start() {
    vm_is_running && return 0
    log_info "Starting VM '$VM_NAME'..."
    "${VIRSH[@]}" start "$VM_DOMAIN" >/dev/null
}

vm_shutdown() {
    "${VIRSH[@]}" shutdown "$VM_DOMAIN" &>/dev/null || true
}

# Pick a host port for a new VM's SSH forward: not in the registry, not
# listening now. Starts above the 222x range other tools like to squat on.
alloc_port() {
    local port used
    used=$(registry_lines | cut -d'|' -f3)
    for port in $(seq 2230 2399); do
        grep -qx "$port" <<< "$used" && continue
        [[ -n "$(ss -Htln "sport = :$port" 2>/dev/null)" ]] && continue
        echo "$port"
        return 0
    done
    die "No free SSH port in 2230-2399"
}

# --- SSH ---
# Run a command on the VM with the user's session bus, as testuser.
vm_ssh() {
    ssh "${SSH_OPTS[@]}" -i "$VM_SSH_KEY" -p "$VM_SSH_PORT" "${SSH_USER}@localhost" \
        "export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus; $*"
}

vm_ssh_interactive() {
    exec ssh "${SSH_OPTS[@]}" -i "$VM_SSH_KEY" -p "$VM_SSH_PORT" "${SSH_USER}@localhost"
}

# Copy host files to the VM.
vm_copy() {
    local dest="${*: -1}"
    local srcs=("${@:1:$#-1}")
    rsync -az -e "ssh ${SSH_OPTS[*]} -i $VM_SSH_KEY -p $VM_SSH_PORT" \
        "${srcs[@]}" "${SSH_USER}@localhost:${dest}"
}

# Wait for SSH. Usage: vm_wait_ssh [timeout_secs]
vm_wait_ssh() {
    local timeout="${1:-180}" elapsed=0
    log_info "Waiting for SSH on '$VM_NAME' (timeout: ${timeout}s)..."
    while (( elapsed < timeout )); do
        if vm_ssh true 2>/dev/null; then
            log_ok "SSH ready on '$VM_NAME' (${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_error "SSH timeout after ${timeout}s for VM '$VM_NAME'"
    return 1
}

shell_pid() { vm_ssh "pgrep -x gnome-shell" 2>/dev/null || true; }

# Wait for gnome-shell to be running (SSH must already answer).
# Usage: vm_wait_shell [timeout_secs]
vm_wait_shell() {
    local timeout="${1:-120}" elapsed=0
    while (( elapsed < timeout )); do
        if [[ -n "$(shell_pid)" ]]; then
            log_ok "GNOME Shell running on '$VM_NAME' (${elapsed}s)"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    log_error "GNOME Shell not running after ${timeout}s on '$VM_NAME'"
    return 1
}

vm_wait_session() {
    vm_wait_ssh "${1:-180}" && vm_wait_shell "${1:-180}"
}

# The guest's clock, in the form journalctl --since takes.
guest_now() { vm_ssh "date '+%Y-%m-%d %H:%M:%S'"; }

# --- Per-VM lock: one test at a time per VM, across all projects ---
# A matrix holds the lock across its whole per-VM step and exports
# GEV_LOCK_HELD so the test it runs does not wait on its own lock.
vm_lock() {
    [[ "${GEV_LOCK_HELD:-}" == "$VM_NAME" ]] && return 0
    ensure_dirs
    exec {GEV_LOCK_FD}>"$GEV_LOCKS/$VM_NAME.lock"
    if ! flock -n "$GEV_LOCK_FD"; then
        log_info "VM '$VM_NAME' is busy with another test; waiting for it..."
        flock -w 3600 "$GEV_LOCK_FD" || die "Timed out waiting for the lock on '$VM_NAME'"
    fi
    export GEV_LOCK_HELD="$VM_NAME"
}

# --- Event log ---
# One JSON object per line in $GEV_RUN_DIR/events.jsonl, with wall-clock time.
# Usage: gev_event <event> [key=value ...]
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

gev_event() {
    [[ -n "${GEV_RUN_DIR:-}" ]] || return 0
    local event="$1" kv out
    shift
    out="{\"ts\":$(json_str "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)")"
    out+=",\"t\":$(date +%s.%3N),\"event\":$(json_str "$event")"
    [[ -n "${VM_NAME:-}" ]] && out+=",\"vm\":$(json_str "$VM_NAME")"
    for kv in "$@"; do
        out+=",$(json_str "${kv%%=*}"):$(json_str "${kv#*=}")"
    done
    echo "$out}" >> "$GEV_RUN_DIR/events.jsonl"
}
