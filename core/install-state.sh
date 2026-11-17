#!/usr/bin/env bash
# Helpers shared by install.sh and uninstall.sh. Only paths explicitly
# registered by the installer are restored or removed by the uninstaller.
: "${RAGNAR_STATE_DIR:=/var/lib/ragnar-panel}"

ragnar_state_init() {
    mkdir -p "$RAGNAR_STATE_DIR/registered" "$RAGNAR_STATE_DIR/original" \
        "$RAGNAR_STATE_DIR/services" || return 1
    chmod 700 "$RAGNAR_STATE_DIR" || return 1
}

ragnar_backup_file() {
    local path="$1" rel marker original
    case "$path" in
        /*) rel=${path#/} ;;
        *) echo "ragnar_backup_file: expected an absolute path: $path" >&2; return 2 ;;
    esac
    marker="$RAGNAR_STATE_DIR/registered/$rel"
    original="$RAGNAR_STATE_DIR/original/$rel"
    [ -e "$marker" ] && return 0

    if [ -e "$path" ] || [ -L "$path" ]; then
        mkdir -p "$(dirname "$original")" || return 1
        cp -a -- "$path" "$original" || return 1
    fi
    mkdir -p "$(dirname "$marker")" || return 1
    : > "$marker"
}

ragnar_capture_generated_file() {
    local path="$1" rel marker original
    case "$path" in
        /*) rel=${path#/} ;;
        *) echo "ragnar_capture_generated_file: expected an absolute path: $path" >&2; return 2 ;;
    esac
    marker="$RAGNAR_STATE_DIR/registered/$rel"
    original="$RAGNAR_STATE_DIR/original/$rel"
    [ -e "$marker" ] || return 2
    if [ -e "$original" ] || [ -L "$original" ]; then
        return 0
    fi
    if [ -e "$path" ] || [ -L "$path" ]; then
        mkdir -p "$(dirname "$original")" || return 1
        cp -a -- "$path" "$original"
    fi
}

ragnar_restore_files() {
    local marker rel path original failed=0
    local registered="$RAGNAR_STATE_DIR/registered"
    [ -d "$registered" ] || return 0

    while IFS= read -r -d '' marker; do
        rel=${marker#"$registered"/}
        path="/$rel"
        original="$RAGNAR_STATE_DIR/original/$rel"
        if [ -d "$path" ] && [ ! -L "$path" ]; then
            echo "Not replacing directory at managed path: $path" >&2
            failed=1
            continue
        fi
        rm -f -- "$path" || { failed=1; continue; }
        if [ -e "$original" ] || [ -L "$original" ]; then
            mkdir -p "$(dirname "$path")" && cp -a -- "$original" "$path" || failed=1
        fi
    done < <(find "$registered" -type f -print0)
    return "$failed"
}

ragnar_capture_service_state() {
    local service="$1" snapshot enabled active
    case "$service" in
        *[!A-Za-z0-9_.@:-]*|"") return 2 ;;
    esac
    snapshot="$RAGNAR_STATE_DIR/services/$service"
    [ -f "$snapshot" ] && return 0

    if command -v systemctl >/dev/null 2>&1; then
        enabled=$(systemctl is-enabled "$service" 2>/dev/null || true)
        active=$(systemctl is-active "$service" 2>/dev/null || true)
        enabled=${enabled:-not-found}
        active=${active:-inactive}
    else
        enabled=unknown
        active=unknown
    fi
    mkdir -p "$(dirname "$snapshot")" || return 1
    printf '%s\n%s\n' "$enabled" "$active" > "$snapshot"
}

ragnar_restore_service_state() {
    local service="$1" snapshot enabled active
    snapshot="$RAGNAR_STATE_DIR/services/$service"
    [ -f "$snapshot" ] || return 2
    IFS= read -r enabled < "$snapshot" || return 1
    active=$(sed -n '2p' "$snapshot")
    command -v systemctl >/dev/null 2>&1 || return 1

    case "$enabled" in
        enabled|enabled-runtime) systemctl enable "$service" >/dev/null 2>&1 || true ;;
        disabled|not-found) systemctl disable "$service" >/dev/null 2>&1 || true ;;
        # Preserve masked/static/indirect units as-is; install.sh cannot
        # successfully enable a masked unit, and these states are not ours.
    esac
    case "$active" in
        active) systemctl start "$service" >/dev/null 2>&1 || true ;;
        inactive|failed) systemctl stop "$service" >/dev/null 2>&1 || true ;;
    esac
}
