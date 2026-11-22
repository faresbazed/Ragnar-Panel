#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export RAGNAR_STATE_DIR="$TMP/state"
. "$ROOT/core/install-state.sh"
ragnar_state_init

mkdir -p "$TMP/etc"
printf 'original\n' > "$TMP/etc/existing.conf"
chmod 640 "$TMP/etc/existing.conf"
ln -s existing.conf "$TMP/etc/original-link"

ragnar_backup_file "$TMP/etc/existing.conf"
ragnar_backup_file "$TMP/etc/original-link"
ragnar_backup_file "$TMP/etc/new.conf"

printf 'changed\n' > "$TMP/etc/existing.conf"
rm "$TMP/etc/original-link"
printf 'created by installer\n' > "$TMP/etc/new.conf"
# Repeated installs must not replace the first snapshot.
ragnar_backup_file "$TMP/etc/existing.conf"

ragnar_restore_files

[ "$(cat "$TMP/etc/existing.conf")" = original ]
[ "$(stat -c '%a' "$TMP/etc/existing.conf")" = 640 ]
[ -L "$TMP/etc/original-link" ]
[ "$(readlink "$TMP/etc/original-link")" = existing.conf ]
[ ! -e "$TMP/etc/new.conf" ]

ragnar_backup_file "$TMP/etc/generated.conf"
printf 'package baseline\n' > "$TMP/etc/generated.conf"
ragnar_capture_generated_file "$TMP/etc/generated.conf"
printf 'Ragnar rules\n' > "$TMP/etc/generated.conf"
ragnar_restore_files
grep -Fqx 'package baseline' "$TMP/etc/generated.conf"

SYSTEMCTL_LOG="$TMP/systemctl.log"
systemctl() {
    case "$1:$2" in
        is-enabled:active-demo.service) printf 'enabled\n' ;;
        is-active:active-demo.service) printf 'active\n' ;;
        is-enabled:inactive-demo.service) printf 'disabled\n' ;;
        is-active:inactive-demo.service) printf 'inactive\n' ;;
        *) printf '%s\n' "$*" >> "$SYSTEMCTL_LOG" ;;
    esac
}
ragnar_capture_service_state active-demo.service
ragnar_capture_service_state inactive-demo.service
ragnar_restore_service_state active-demo.service
ragnar_restore_service_state inactive-demo.service
grep -Fqx 'enable active-demo.service' "$SYSTEMCTL_LOG"
grep -Fqx 'start active-demo.service' "$SYSTEMCTL_LOG"
grep -Fqx 'disable inactive-demo.service' "$SYSTEMCTL_LOG"
grep -Fqx 'stop inactive-demo.service' "$SYSTEMCTL_LOG"
ragnar_mark_installed xray
ragnar_was_installed xray
if ragnar_was_installed sing-box; then exit 1; fi
if ragnar_mark_installed '../escape' 2>/dev/null; then exit 1; fi
[ ! -e "$RAGNAR_STATE_DIR/escape" ]

ragnar_backup_file "$TMP/etc/protected.conf"
mkdir "$TMP/etc/protected.conf"
if ragnar_restore_files; then exit 1; fi
[ -d "$TMP/etc/protected.conf" ]
rmdir "$TMP/etc/protected.conf"

# A missing original is not evidence a file was created by Ragnar.
mv "$RAGNAR_STATE_DIR/original$TMP/etc/existing.conf" "$TMP/saved"
printf 'live\n' > "$TMP/etc/existing.conf"
if ragnar_restore_files; then exit 1; fi
grep -Fqx live "$TMP/etc/existing.conf"
mv "$TMP/saved" "$RAGNAR_STATE_DIR/original$TMP/etc/existing.conf"
ragnar_restore_files
grep -Fqx original "$TMP/etc/existing.conf"

mkdir "$TMP/redirected"
mv "$TMP/etc" "$TMP/real-etc"
ln -s "$TMP/redirected" "$TMP/etc"
printf 'unrelated\n' > "$TMP/redirected/new.conf"
if ragnar_restore_files; then exit 1; fi
grep -Fqx unrelated "$TMP/redirected/new.conf"

printf 'enabled\n' > "$RAGNAR_STATE_DIR/services/truncated"
if ragnar_restore_service_state truncated; then exit 1; fi
printf 'invalid\nactive\n' > "$RAGNAR_STATE_DIR/services/invalid"
if ragnar_restore_service_state invalid; then exit 1; fi
printf 'install-state helper checks passed\n'
