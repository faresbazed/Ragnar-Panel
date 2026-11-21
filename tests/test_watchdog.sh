#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export RESTART_LOG="$TMP/restarts"
export ENABLED_UNITS="haproxy xray sing-box zivpn ragnar-web"

systemctl() {
    local action=$1 unit
    shift
    if [[ ${1:-} == --quiet ]]; then
        shift
    fi
    case "$action" in
        is-active)
            # systemctl succeeds if any queried unit is active.
            for unit; do
                if [[ " $ACTIVE_UNITS " == *" $unit "* ]]; then
                    return 0
                fi
            done
            return 3
            ;;
        list-unit-files)
            [[ " $ENABLED_UNITS udp-custom " == *" ${1%.service} "* ]]
            ;;
        is-enabled)
            [[ " $ENABLED_UNITS " == *" $1 "* ]]
            ;;
        restart)
            printf '%s\n' "$@" >> "$RESTART_LOG"
            ;;
        *)
            printf 'Unexpected systemctl action: %s\n' "$action" >&2
            return 1
            ;;
    esac
}

ss() {
    printf '%s\n' 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:* users:(("haproxy",pid=123,fd=4))'
}

logger() { :; }
export -f systemctl ss logger

check_restarts() {
    local scenario=$1 active=$2 expected=$3
    : > "$RESTART_LOG"
    ACTIVE_UNITS="$active" bash "$ROOT/core/watchdog.sh"
    if ! diff -u <(printf '%s' "$expected") "$RESTART_LOG"; then
        printf 'FAIL: %s\n' "$scenario" >&2
        return 1
    fi
    printf 'PASS: %s\n' "$scenario"
}

check_restarts 'partial outage restarts only failed, enabled units (xray and ragnar-web)' \
    'haproxy sing-box zivpn' $'xray\nragnar-web\n'
check_restarts 'no restarts when all enabled units are active' "$ENABLED_UNITS" ''
