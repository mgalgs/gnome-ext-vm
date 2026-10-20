# shellcheck shell=bash
# shellcheck disable=SC2034  # the config's variables are read by the other files
# Per-project config: find it, load it, resolve its paths.
# The format is documented in README.md ("Project config").

CONFIG_NAMES=(gnome-ext-vm.conf testing/gnome-ext-vm.conf testing/vm/gnome-ext-vm.conf)

# Print the config path: --config, then $GEV_CONFIG, then the first match of
# CONFIG_NAMES in the current directory or any parent.
config_find() {
    local explicit="$1" dir name
    if [[ -n "$explicit" ]]; then
        [[ -f "$explicit" ]] || die "Config not found: $explicit"
        realpath "$explicit"
        return
    fi
    if [[ -n "${GEV_CONFIG:-}" ]]; then
        [[ -f "$GEV_CONFIG" ]] || die "GEV_CONFIG points at a missing file: $GEV_CONFIG"
        realpath "$GEV_CONFIG"
        return
    fi
    dir="$PWD"
    while :; do
        for name in "${CONFIG_NAMES[@]}"; do
            if [[ -f "$dir/$name" ]]; then
                echo "$dir/$name"
                return
            fi
        done
        [[ "$dir" == / ]] && return 1
        dir="$(dirname "$dir")"
    done
}

# Resolve a config-relative path to an absolute one ("" stays "").
config_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    [[ "$p" == /* ]] || p="$CONFIG_DIR/$p"
    realpath -m "$p"
}

# Load the project config into this shell. Usage: config_load <path> [required]
# With "required", a missing config is fatal; otherwise HAVE_CONFIG=false and
# only the VM-management commands work.
config_load() {
    local path
    HAVE_CONFIG=false
    if ! path=$(config_find "$1"); then
        [[ "${2:-}" == required ]] && die "No project config found (looked for ${CONFIG_NAMES[*]} here and in parent directories; or pass --config)"
        RESULTS_DIR="${RESULTS_DIR:-$GEV_DATA/results}"
        return 0
    fi
    CONFIG_FILE="$path"
    CONFIG_DIR="$(dirname "$path")"

    EXT_UUID="" EXT_BUILD="" EXT_ZIP="" EXT_SRC_DIR=""
    GUEST_PACKAGES_FEDORA="" GUEST_PACKAGES_DEBIAN=""
    LOG_FILTER="" MATRIX="" DEFAULT_VM="" RESULTS_DIR="" PROJECT_ROOT=""
    HOOK_PRE_DEPLOY="" HOOK_POST_DEPLOY="" HOOK_TEST="" HOOK_VARIANTS="" HOOK_HOTRELOAD_SETUP=""

    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    HAVE_CONFIG=true

    [[ -n "$EXT_UUID" ]] || die "$CONFIG_FILE: EXT_UUID is required"
    if [[ -n "$PROJECT_ROOT" ]]; then
        PROJECT_ROOT=$(config_path "$PROJECT_ROOT")
    else
        PROJECT_ROOT=$(git -C "$CONFIG_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$CONFIG_DIR")
    fi
    RESULTS_DIR=$(config_path "${RESULTS_DIR:-results}")
    EXT_SRC_DIR=$(config_path "$EXT_SRC_DIR")
    if [[ -n "$EXT_BUILD" && -z "$EXT_ZIP" ]]; then
        EXT_ZIP="dist/${EXT_UUID}.zip"
    fi
    if [[ -n "$EXT_ZIP" && "$EXT_ZIP" != /* ]]; then
        EXT_ZIP="$PROJECT_ROOT/$EXT_ZIP"
    fi
    if [[ -z "$EXT_BUILD" && -z "$EXT_SRC_DIR" ]]; then
        die "$CONFIG_FILE: set EXT_BUILD (a build command) or EXT_SRC_DIR (an extension source dir)"
    fi
    [[ -n "$LOG_FILTER" ]] || LOG_FILTER="${EXT_UUID%%@*}"
    local h
    for h in HOOK_PRE_DEPLOY HOOK_POST_DEPLOY HOOK_TEST HOOK_VARIANTS HOOK_HOTRELOAD_SETUP; do
        printf -v "$h" '%s' "$(config_path "${!h}")"
        [[ -z "${!h}" || -f "${!h}" ]] || die "$CONFIG_FILE: $h names a missing file: ${!h}"
    done
}

# Matrix VM names: MATRIX from the config, else every created VM.
config_matrix() {
    if [[ -n "${MATRIX:-}" ]]; then
        tr ' ' '\n' <<< "$MATRIX" | grep -v '^$'
    else
        registry_names
    fi
}

# The VM a command uses when --vm is not given.
config_default_vm() {
    if [[ -n "${DEFAULT_VM:-}" ]]; then
        echo "$DEFAULT_VM"
    else
        config_matrix | sed -n 1p
    fi
}

# Guest packages this project needs on the current VM's distro family.
config_packages() {
    case "$(vm_family)" in
        fedora) echo "${GUEST_PACKAGES_FEDORA:-}" ;;
        debian) echo "${GUEST_PACKAGES_DEBIAN:-}" ;;
    esac
}

# Run a project hook script with the run's context in its environment.
# Usage: run_hook <HOOK_VAR> [args...]. A missing hook is a no-op.
run_hook() {
    local var="$1" path rc=0
    shift
    path="${!var:-}"
    [[ -n "$path" ]] || return 0
    log_info "Running hook ${var#HOOK_}: $path"
    gev_event hook_start hook="${var#HOOK_}" path="$path"
    (
        export GEV_VM="$VM_NAME" GEV_DOMAIN="$VM_DOMAIN" GEV_SSH_PORT="$VM_SSH_PORT"
        export GEV_UUID="$EXT_UUID" GEV_PROJECT_ROOT="$PROJECT_ROOT"
        export GEV_CONFIG="$CONFIG_FILE" GEV_RUN_DIR="${GEV_RUN_DIR:-}"
        export GEV_LABEL="${LABEL:-}" GEV_RESULTS_DIR="$RESULTS_DIR"
        export PATH="$GEV_ROOT/bin:$PATH"
        cd "$PROJECT_ROOT"
        bash "$path" "$@"
    ) || rc=$?
    gev_event hook_end hook="${var#HOOK_}" rc="$rc"
    return "$rc"
}
