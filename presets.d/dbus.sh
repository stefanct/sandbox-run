# D-Bus proxy support for sandboxed desktop integrations.
#
# Presets can request access with:
#   dbus_talk "org.example.Service"
#   dbus_call "org.example.Service=org.example.Interface.Method@/object/path"
#   dbus_broadcast "org.example.Service=org.example.Interface.Signal@/object/path"
#
# Users can request machine-local access with colon-separated environment vars:
#   SANDBOX_RUN_DBUS_TALK="org.example.Service:org.example.Other"
#   SANDBOX_RUN_DBUS_CALL="org.example.Service=org.example.Interface.Method@/object/path"
#   SANDBOX_RUN_DBUS_BROADCAST="org.example.Service=org.example.Interface.Signal@/object/path"
#
# The proxy is started from finalize_dbus after all presets have run, so
# permissions collected by later presets and environment variables are included.
declare -p SANDBOX_RUN_FINALIZERS >/dev/null 2>&1 || SANDBOX_RUN_FINALIZERS=()
declare -p DBUS_TALK_NAMES >/dev/null 2>&1 || DBUS_TALK_NAMES=()
declare -p DBUS_CALL_RULES >/dev/null 2>&1 || DBUS_CALL_RULES=()
declare -p DBUS_BROADCAST_RULES >/dev/null 2>&1 || DBUS_BROADCAST_RULES=()
declare -p DBUS_ENV_PARSED >/dev/null 2>&1 || DBUS_ENV_PARSED=0

# Register the finalizer at source time. It is harmless when no preset requests
# D-Bus permissions. Guard against duplicate registration when a user override
# sources or copies this preset.
if [[ " ${SANDBOX_RUN_FINALIZERS[*]} " != *" finalize_dbus "* ]]; then
    SANDBOX_RUN_FINALIZERS+=(finalize_dbus)
fi

dbus_talk() {
    DBUS_TALK_NAMES+=("$@")
}

dbus_call() {
    DBUS_CALL_RULES+=("$@")
}

dbus_broadcast() {
    DBUS_BROADCAST_RULES+=("$@")
}

_dbus_add_colon_env() {
    local var="$1"
    local -n target="$2"
    local value="${!var:-}"
    local item
    local -a items

    [[ -z "$value" ]] && return

    IFS=':' read -ra items <<< "$value"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] && target+=("$item")
    done
}

_dbus_collect_env() {
    [[ "$DBUS_ENV_PARSED" == "1" ]] && return
    DBUS_ENV_PARSED=1

    _dbus_add_colon_env SANDBOX_RUN_DBUS_TALK DBUS_TALK_NAMES
    _dbus_add_colon_env SANDBOX_RUN_DBUS_CALL DBUS_CALL_RULES
    _dbus_add_colon_env SANDBOX_RUN_DBUS_BROADCAST DBUS_BROADCAST_RULES
}

finalize_dbus() {
    _dbus_collect_env

    if [[ ${#DBUS_TALK_NAMES[@]} -eq 0 && ${#DBUS_CALL_RULES[@]} -eq 0 && ${#DBUS_BROADCAST_RULES[@]} -eq 0 ]]; then
        return
    fi

    if ! command -v xdg-dbus-proxy >/dev/null 2>&1; then
        yell "xdg-dbus-proxy not found, D-Bus features disabled (install xdg-dbus-proxy)"
        return
    fi

    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        yell "DBUS_SESSION_BUS_ADDRESS not set, D-Bus features disabled"
        return
    fi

    local proxy_dir proxy_socket name rule
    local -a proxy_args summary

    proxy_dir=$(mktemp -d)
    proxy_socket="$proxy_dir/bus"
    CLEANUP_FILES+=("$proxy_dir")

    proxy_args=(--filter)
    for name in "${DBUS_TALK_NAMES[@]}"; do
        proxy_args+=("--talk=$name")
        summary+=("talk:$name")
    done
    for rule in "${DBUS_CALL_RULES[@]}"; do
        proxy_args+=("--call=$rule")
        summary+=("call:$rule")
    done
    for rule in "${DBUS_BROADCAST_RULES[@]}"; do
        proxy_args+=("--broadcast=$rule")
        summary+=("broadcast:$rule")
    done

    xdg-dbus-proxy "$DBUS_SESSION_BUS_ADDRESS" "$proxy_socket" \
        "${proxy_args[@]}" &
    CLEANUP_PIDS+=("$!")

    # Wait for proxy socket to appear.
    for _ in {1..50}; do
        [[ -S "$proxy_socket" ]] && break
        sleep 0.1
    done

    if [[ -S "$proxy_socket" ]]; then
        yell "D-Bus proxy enabled (${summary[*]})"
        EXTRA_BWRAP_OPTS+=(--bind "$proxy_dir" "$proxy_dir")
        ENV_PRESET_OPTS+=(--setenv DBUS_SESSION_BUS_ADDRESS "unix:path=$proxy_socket")
    else
        die "D-Bus proxy failed to start"
    fi
}

# D-Bus permissions for desktop notifications.
configure_dbus() {
    dbus_talk "org.freedesktop.Notifications"
}
