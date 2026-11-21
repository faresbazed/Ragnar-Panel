#!/bin/bash
# =====================================================================
# Ragnar VPS Management Panel - self-update
# Telegram : @farisbazed      Channel : https://t.me/ragnaresim
#
# Downloads the latest code from GitHub (main branch), backs up the
# whole panel state (/etc/ragnar: users, settings, certs, SlowDNS
# keys), then re-runs the installer from the fresh copy. The installer
# preserves users, settings, keys and certificates, so an update never
# wipes the panel - it only replaces code and restarts services.
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
        if [ -z "${RAGNAR_UPDATE_COPY:-}" ]; then
            _tmp="$(mktemp /tmp/ragnar-update-self.XXXXXX.sh)"
            cp "$0" "$_tmp" && chmod 755 "$_tmp"
            RAGNAR_UPDATE_COPY=1 exec bash "$_tmp" "$@"
        fi
        ;;
esac

say() { echo -e "\033[96m[UPDATE]\033[0m $*"; }
err() { echo -e "\033[91m[UPDATE] $*\033[0m" >&2; }

write_status() {  # write_status <state> <version> <message>
    python3 - "$STATUS" "$1" "$2" "$3" <<'PY' 2>/dev/null || true
import json, sys, datetime
data = {"state": sys.argv[2], "version": sys.argv[3],
        "message": sys.argv[4],
        "time": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
with open(sys.argv[1], "w") as f:
    json.dump(data, f, indent=1)
PY
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
    echo "$sha"
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
mkdir -p "$BASE" /var/lock
exec 9>"$LOCK"
if ! flock -n 9; then
    err "An update is already running."
    write_status "running" "$(current_sha)" "An update is already running."
    exit 1
fi

FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
{
    echo "===== update run $(date -Is) ====="
} >> "$LOG"

cur="$(current_sha)"
write_status "running" "$cur" "Checking GitHub for the latest version..."
lat="$(latest_sha)"
if [ -z "$lat" ] && [ "$FORCE" = 0 ]; then
    err "Could not reach GitHub - update aborted, nothing changed."
    write_status "failed" "$cur" "Could not reach GitHub; nothing changed."
    exit 1
fi
say "Installed: $(short "$cur")   Latest: $(short "${lat:-main}")"
if [ "$FORCE" = 0 ] && [ -n "$cur" ] && [ -n "$lat" ] && [ "$cur" = "$lat" ]; then
    say "Already up to date - nothing to do (pass --force to reinstall files)."
    write_status "uptodate" "$cur" "Already up to date."
    exit 0
fi

WORK="$(mktemp -d /tmp/ragnar-update.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

TAR_REF="${lat:-refs/heads/main}"
say "Downloading the latest panel code..."
if ! curl -fsSL --max-time 300 -H "Cache-Control: no-cache" \
        "https://codeload.github.com/$REPO/tar.gz/$TAR_REF" -o "$WORK/src.tgz" \
        >> "$LOG" 2>&1; then
    err "Download failed - update aborted, nothing changed."
    write_status "failed" "$cur" "Download failed; nothing changed."
    exit 1
fi
tar -xzf "$WORK/src.tgz" -C "$WORK"
SRC_DIR="$(dirname "$(find "$WORK" -maxdepth 2 -name install.sh | head -1)")"
if [ -z "$SRC_DIR" ] || [ ! -f "$SRC_DIR/install.sh" ]; then
    err "Downloaded archive looks wrong - update aborted, nothing changed."
    write_status "failed" "$cur" "Bad download; nothing changed."
    exit 1
fi

BACKUP="/root/ragnar-backup-pre-update-$(date +%Y%m%d-%H%M%S).tar.gz"
say "Backing up panel state to $BACKUP ..."
if ! tar -czf "$BACKUP" -C "$(dirname "$BASE")" "$(basename "$BASE")" \
        >> "$LOG" 2>&1; then
    err "Backup failed - update aborted, nothing changed."
    write_status "failed" "$cur" "Backup failed; nothing changed."
    exit 1
fi

# Directly replace all core, CLI, and Web Panel files up front so they are
# guaranteed to match the downloaded release on disk immediately.
mkdir -p "$BASE"/{core,web}
rm -rf "$BASE/core/__pycache__" "$BASE/web/__pycache__"
[ -f "$SRC_DIR/configs/dnstt-server.patch" ] && install -m 644 "$SRC_DIR/configs/dnstt-server.patch" "$BASE/core/dnstt-server.patch"
for f in ragnar.py checker.py wsproxy.py install-state.sh watchdog.sh slowdns-setup.sh update.sh; do
    [ -f "$SRC_DIR/core/$f" ] && install -m 755 "$SRC_DIR/core/$f" "$BASE/core/$f"
done
[ -f "$SRC_DIR/menu.sh" ]       && install -m 755 "$SRC_DIR/menu.sh" "$BASE/menu.sh"
[ -f "$SRC_DIR/uninstall.sh" ]  && install -m 755 "$SRC_DIR/uninstall.sh" "$BASE/uninstall.sh"
[ -f "$SRC_DIR/web/webpanel.py" ] && install -m 755 "$SRC_DIR/web/webpanel.py" "$BASE/web/webpanel.py"
rm -f /usr/local/bin/menu /usr/local/bin/ragnar
ln -s "$BASE/menu.sh" /usr/local/bin/menu
ln -s "$BASE/menu.sh" /usr/local/bin/ragnar

# Feed the installer the saved domain/NS so it never prompts.
eval "$(python3 - "$BASE/settings.json" <<'PY' 2>/dev/null
import json, shlex, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    s = {}
for key, var in (("domain", "RAGNAR_DOMAIN"), ("ns", "RAGNAR_NS")):
    val = (s.get(key) or "").strip()
    if val:
        print(f"export {var}={shlex.quote(val)}")
PY
)"

REC_VER="${lat:-$(date +%Y%m%d%H%M%S)}"
say "Installing the new version (users, keys and settings are kept)..."
write_status "running" "$REC_VER" "Installing version $(short "$REC_VER")..."
( cd "$SRC_DIR" && RAGNAR_UPDATE=1 bash install.sh ) 2>&1 | tee -a "$LOG"
rc="${PIPESTATUS[0]}"
if [ "$rc" != 0 ]; then
    err "Installer failed (exit $rc) - see $LOG"
    err "Your previous state is backed up at $BACKUP"
    write_status "failed" "$cur" \
        "Installer failed (exit $rc). Backup of the old state: $BACKUP"
    exit "$rc"
fi

printf '%s %s\n' "$REC_VER" "$(date -Is)" > "$VERSION_FILE"
write_status "done" "$REC_VER" "Updated to $(short "$REC_VER"). Backup: $BACKUP"
systemctl restart ragnar-web 2>/dev/null || true
say "Panel updated to version $(short "$REC_VER")."
exit 0
