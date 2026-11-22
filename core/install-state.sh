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
    if [ -e "$original" ] || [ -L "$original" ]; then
        printf 'original\n' > "$marker"
    else
        : > "$marker"
    fi
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
        cp -a -- "$path" "$original" && printf 'original\n' > "$marker"
    fi
}

ragnar_restore_files() (
    local marker rel path original parent stage skip list failed=0
    local registered="$RAGNAR_STATE_DIR/registered"
    list=$(mktemp) || return 1
    trap 'rm -f -- "$list"' EXIT
    find "$registered" ! -type d -print0 > "$list" || return 1
    while IFS= read -r -d '' marker; do
        rel=${marker#"$registered"/}
        path="/$rel"
        if [ ! -f "$marker" ] || [ -L "$marker" ]; then
            echo "Invalid installer record: $marker" >&2
            failed=1
            continue
        fi
        for skip in "$@"; do
            [ "$path" != "$skip" ] || continue 2
        done
        original="$RAGNAR_STATE_DIR/original/$rel"
        parent=$(dirname -- "$path")
        if [ "$(realpath -m -- "$parent")" != "$parent" ] || { [ -d "$path" ] && [ ! -L "$path" ]; }; then
            echo "Not replacing directory or writing through a linked directory: $path" >&2
            failed=1
            continue
        fi
        if [ -f "$original" ] || [ -L "$original" ]; then
            mkdir -p -- "$parent" && stage=$(mktemp -d -- "$parent/.ragnar-restore.XXXXXX") || { failed=1; continue; }
            cp -a -- "$original" "$stage/file" && mv -fT -- "$stage/file" "$path" || failed=1
            rm -rf -- "$stage" || failed=1
        elif [ -s "$marker" ] || [ -e "$original" ]; then
            echo "Missing or invalid original for $path" >&2
            failed=1
        else
            # Empty markers from older versions also use the original's
            # presence to distinguish a backup from a panel-created file.
            rm -f -- "$path" || failed=1
        fi
    done < "$list"
    return "$failed"
)

# Components the installer itself downloaded (absent before Ragnar) are
# recorded here so uninstall removes them without touching pre-existing ones.
ragnar_mark_installed() {
    case "$1" in
        *[!A-Za-z0-9_.-]*|"") return 2 ;;
    esac
    mkdir -p "$RAGNAR_STATE_DIR/installed" || return 1
    : > "$RAGNAR_STATE_DIR/installed/$1"
}

ragnar_was_installed() {
    [ -f "$RAGNAR_STATE_DIR/installed/$1" ]
}

# udp-custom adds these untagged rules itself. Only compare complete,
# recognizable specifications; a rule with extra matches is not ours.
ragnar_udp_custom_rules() (
    set -o pipefail
    { iptables -S INPUT && iptables -t nat -S PREROUTING; } | awk '
        $0 == "-A INPUT -p udp -m udp --dport 36712 -j ACCEPT" ||
        /^-A PREROUTING( -[di] [[:alnum:].\/:_+-]+)* -p udp -m udp --dport 1:65535 -j DNAT --to-destination :36712$/'
)

ragnar_capture_udp_custom_rules() {
    local snapshot="$RAGNAR_STATE_DIR/udp-custom-before" tmp
    [ ! -e "$snapshot" ] || return 0
    tmp=$(mktemp -- "$snapshot.XXXXXX") || return 1
    if ragnar_udp_custom_rules > "$tmp" && mv -T -- "$tmp" "$snapshot"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
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
    [ -n "$enabled" ] && [ -n "$active" ] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1

    case "$active" in
        active|inactive|failed|unknown|activating|deactivating|reloading|refreshing|maintenance) ;;
        *) echo "Invalid active state in $snapshot" >&2; return 1 ;;
    esac
    case "$enabled" in
        not-found)
            # A removed unit is already restored. Packages deliberately
            # left installed may still provide a unit that must be disabled.
            [ "$(systemctl show --property=LoadState --value "$service")" != not-found ] || return 0
            systemctl disable "$service" || return 1 ;;
        enabled) systemctl enable "$service" || return 1 ;;
        enabled-runtime) systemctl disable "$service" && systemctl enable --runtime "$service" || return 1 ;;
        disabled) systemctl disable "$service" || return 1 ;;
        masked|masked-runtime|static|indirect|alias|linked|linked-runtime|generated|transient|unknown|bad) ;;
        *) echo "Invalid enablement state in $snapshot" >&2; return 1 ;;
    esac
    case "$active" in
        active) systemctl start "$service" ;;
        inactive|failed) systemctl stop "$service" ;;
    esac
}
