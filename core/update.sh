#!/bin/bash
# =====================================================================
# Ragnar VPS Management Panel - self-update
# Telegram : @farisbazed      Channel : https://t.me/ragnaresim
#
# Downloads the latest code from GitHub (main branch), backs up the
# whole panel state (/etc/ragnar: users, settings, certs, SlowDNS
# keys), then re-runs the installer from the fresh copy. A failed install
# keeps the previous version marker and reports the recovery archive.
#
# Usage:
#   update.sh           perform the update (skips if already latest)
#   update.sh --force   update even if the version looks current
#   update.sh check     print installed vs latest version, change nothing
#
# State files (read by menu.sh and the web panel):
#   /etc/ragnar/version         "<git sha> <date>" of the installed code
#   /etc/ragnar/update-status.json   last run: state/version/message/time
#   /etc/ragnar/update.log      full installer output of update runs
# =====================================================================
set -u
BASE="${RAGNAR_DIR:-/etc/ragnar}"
REPO="faresbazed/ragnar-vps-panel"
LOG="$BASE/update.log"
STATUS="$BASE/update-status.json"
VERSION_FILE="$BASE/version"
LOCK="/var/lock/ragnar-update.lock"

# The installer replaces this very script while an update runs, and a
# shell reading a file that changes under it can skip or garble lines.
# When running from the installed copy, re-exec from a temp copy first.
case "$0" in
    "$BASE"/*)
        if [ "${1:-}" != check ] && [ -z "${RAGNAR_UPDATE_COPY:-}" ]; then
            _tmp="$(mktemp /tmp/ragnar-update-self.XXXXXX.sh)" || exit 1
            trap 'rm -f "$_tmp"' EXIT
            cp "$0" "$_tmp" || exit 1
            RAGNAR_UPDATE_COPY=1 bash "$_tmp" "$@"
            exit $?
        fi
        ;;
esac

say() { echo -e "\033[96m[UPDATE]\033[0m $*"; }
err() { echo -e "\033[91m[UPDATE] $*\033[0m" >&2; }

write_status() {  # write_status <state> <version> <message>
    local tmp
    tmp=$(mktemp "$BASE/.update-status.XXXXXX") || exit 1
    if python3 - "$tmp" "$1" "$2" "$3" <<'PY'
import json, sys, datetime
data = {"state": sys.argv[2], "version": sys.argv[3],
        "message": sys.argv[4],
        "time": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=1)
PY
    then
        mv -fT "$tmp" "$STATUS" && return
    fi
    rm -f "$tmp"
    err "Cannot write update status to $STATUS"
    exit 1
}

current_sha() {
    [ -f "$VERSION_FILE" ] && awk 'NR==1 {print $1}' "$VERSION_FILE" || echo ""
}

latest_sha() {
    local sha=""
    if command -v git >/dev/null 2>&1; then
        sha="$(git ls-remote "https://github.com/$REPO.git" refs/heads/main 2>/dev/null | awk 'NR==1 {print $1}')"
    fi
    if [ -z "$sha" ]; then
        sha="$(curl -fsS --max-time 25 -H "Cache-Control: no-cache" \
            "https://api.github.com/repos/$REPO/commits/main?t=$(date +%s)" 2>/dev/null \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null || echo "")"
    fi
    if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then echo "$sha"; fi
}

short() { [ -n "$1" ] && echo "${1:0:7}" || echo "unknown"; }

# ---------------------------------------------------------------------
if [ "${1:-}" = "check" ]; then
    cur="$(current_sha)"; lat="$(latest_sha)"
    [ -n "$lat" ] || { err "Could not reach GitHub."; exit 1; }
    echo "Installed: $(short "$cur")"
    echo "Latest   : $(short "$lat")"
    if [ -n "$cur" ] && [ "$cur" = "$lat" ]; then
        echo "The panel is up to date."
    else
        echo "An update is available."
    fi
    exit 0
fi

# ---------------------------------------------------------------------
[ "$(id -u)" = 0 ] || { err "Run as root."; exit 1; }
[ "$BASE" = /etc/ragnar ] || { err "The installer only supports /etc/ragnar; refusing to back up a different directory."; exit 1; }
mkdir -p "$BASE" /var/lock || exit 1
exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
    err "An update is already running."
    exit 1
fi

FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
touch "$LOG" && chmod 600 "$LOG" || exit 1
{
    echo "===== update run $(date -Is) ====="
} >> "$LOG"

cur="$(current_sha)"
write_status "running" "$cur" "Checking GitHub for the latest version..."
lat="$(latest_sha)"
if [ -z "$lat" ]; then
    err "Could not reach GitHub - update aborted, nothing changed."
    write_status "failed" "$cur" "Could not reach GitHub; nothing changed."
    exit 1
fi
say "Installed: $(short "$cur")   Latest: $(short "$lat")"
if [ "$FORCE" = 0 ] && [ "$cur" = "$lat" ]; then
    say "Already up to date - nothing to do (pass --force to reinstall files)."
    write_status "uptodate" "$cur" "Already up to date."
    exit 0
fi

WORK="$(mktemp -d /tmp/ragnar-update.XXXXXX)" || { write_status "failed" "$cur" "Cannot create download directory."; exit 1; }
trap 'rm -rf "$WORK"' EXIT

say "Downloading the latest panel code..."
if ! curl -fsSL --max-time 300 -H "Cache-Control: no-cache" \
        "https://codeload.github.com/$REPO/tar.gz/$lat" -o "$WORK/src.tgz" \
        >> "$LOG" 2>&1; then
    err "Download failed - update aborted, nothing changed."
    write_status "failed" "$cur" "Download failed; nothing changed."
    exit 1
fi
if ! tar -xzf "$WORK/src.tgz" -C "$WORK" >> "$LOG" 2>&1; then
    write_status "failed" "$cur" "Archive extraction failed; nothing changed."
    exit 1
fi
installers=("$WORK"/*/install.sh)
if [ "${#installers[@]}" != 1 ] || [ ! -f "${installers[0]}" ]; then
    err "Downloaded archive looks wrong - update aborted, nothing changed."
    write_status "failed" "$cur" "Bad download; nothing changed."
    exit 1
fi
SRC_DIR=${installers[0]%/install.sh}

BACKUP=$(mktemp "/root/ragnar-backup-pre-update-$(date +%Y%m%d-%H%M%S)-XXXXXX.tar.gz") || {
    write_status "failed" "$cur" "Cannot create backup; nothing changed."
    exit 1
}
say "Backing up panel state to $BACKUP ..."
# Enter the data directory even if /etc/ragnar itself is a symlink. Keep
# the historical ragnar/ archive prefix without following interior symlinks.
backup_cmd=(tar -czf "$BACKUP" -C "$BASE" '--transform=flags=rh;s|^\.|ragnar|' .)
# Don't archive different halves of an in-flight panel account transaction.
if [ -d "$BASE/db" ]; then
    backup_cmd=(flock -x -w 60 "$BASE/db/accounts.lock" "${backup_cmd[@]}")
fi
if ! "${backup_cmd[@]}" >> "$LOG" 2>&1; then
    err "Backup failed - update aborted, nothing changed."
    rm -f -- "$BACKUP"
    write_status "failed" "$cur" "Backup failed; nothing changed."
    exit 1
fi

# The installer alone validates state, snapshots command links and deploys code.
REC_VER="$lat"
say "Installing the new version (users, keys and settings are kept)..."
write_status "running" "$cur" "Installing version $(short "$REC_VER")..."
( cd "$SRC_DIR" && unset RAGNAR_DOMAIN RAGNAR_NS && RAGNAR_UPDATE=1 bash install.sh ) 2>&1 | tee -a "$LOG"
rc="${PIPESTATUS[0]}"
if [ "$rc" != 0 ]; then
    err "Installer failed (exit $rc) - see $LOG"
    err "Your previous state is backed up at $BACKUP"
    write_status "failed" "$cur" \
        "Installer failed (exit $rc). Backup of the old state: $BACKUP"
    exit "$rc"
fi

if ! { ver_tmp=$(mktemp "$BASE/.version.XXXXXX") &&
       printf '%s %s\n' "$REC_VER" "$(date -Is)" > "$ver_tmp" &&
       mv -fT "$ver_tmp" "$VERSION_FILE"; }; then
    [ -z "$ver_tmp" ] || rm -f -- "$ver_tmp"
    write_status "failed" "$cur" "Cannot record installed version. Backup: $BACKUP"
    exit 1
fi
write_status "done" "$REC_VER" "Updated to $(short "$REC_VER"). Backup: $BACKUP"
systemctl restart ragnar-web 2>/dev/null || true
say "Panel updated to version $(short "$REC_VER")."
exit 0
