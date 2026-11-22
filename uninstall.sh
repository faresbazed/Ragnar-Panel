#!/bin/bash
# Ragnar VPS Management Panel - uninstaller
# Removes Ragnar-owned services/configuration and restores saved originals.
# Panel-created Linux users are listed and removed only after confirmation.
set -u
BASE="/etc/ragnar"
RAGNAR_STATE_DIR="${RAGNAR_STATE_DIR:-/var/lib/ragnar-panel}"
STATE_DIR="$RAGNAR_STATE_DIR"
die() { echo "Uninstall stopped: $*" >&2; exit 1; }
registered() { [ -f "$STATE_DIR/registered$1" ] && [ ! -L "$STATE_DIR/registered$1" ]; }
installed_by_ragnar() { [ -f "$STATE_DIR/installed/$1" ] && [ ! -L "$STATE_DIR/installed/$1" ]; }
# The sister panel (/etc/vps-panel) reuses Xray, sing-box and cloudflared, so
# components Ragnar downloaded are kept while it is installed.
sister_panel_present() {
    [ -d /usr/local/share/vps-panel ] && return 0
    [ -d /etc/vps-panel ] && find /etc/vps-panel -mindepth 1 -maxdepth 1 ! -name slowdns | grep -q .
}

[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
if [ ! -e "$BASE" ] && [ ! -e "$STATE_DIR/registered" ]; then
    echo "No Ragnar installation found; nothing changed."
    exit 0
fi
[ -f "$BASE/core/ragnar.py" ] || die "Missing panel files; nothing changed."
[ -r "$BASE/core/install-state.sh" ] || die "Missing installer state helper; nothing changed."
# Use the helper shipped with this uninstaller, including when run from a checkout.
. "$(dirname "${BASH_SOURCE[0]}")/core/install-state.sh" || die "Cannot load state helper."
[ "$STATE_DIR" != / ] && [ "$(realpath -e -- "$STATE_DIR")" = "$STATE_DIR" ] &&
    [ "$(stat -c '%u:%a' -- "$STATE_DIR")" = 0:700 ] ||
    die "Expected a private, root-owned installer state directory at $STATE_DIR; nothing changed."
for dir in registered original services; do
    [ -d "$STATE_DIR/$dir" ] && [ ! -L "$STATE_DIR/$dir" ] ||
        die "Missing or invalid installer state: $STATE_DIR/$dir; nothing changed."
done
[ ! -L "$STATE_DIR/installed" ] || die "Invalid component records; nothing changed."
[ -n "$(find "$STATE_DIR/registered" -type f -print -quit)" ] || die "Empty file registry; nothing changed."
echo "This removes Ragnar Panel services, configs and firewall rules."
a=""
read -rp "Continue? [y/N] " a || true
[ "$a" = y ] || exit 0

# HAProxy is the front door, so stop it before its backends. Do not change
# enablement yet: the pre-install state is restored after the files/units.
managed_units=()
stop_unit() {
    systemctl stop "$1" || [ "$(systemctl show --property=LoadState --value "$1")" = not-found ] ||
        die "Cannot stop $1; state retained."
}
if registered /etc/haproxy/haproxy.cfg; then stop_unit haproxy; fi
for unit in ragnar-check.timer ragnar-watchdog.timer ragnar-check.service ragnar-watchdog.service \
            xray.service sing-box.service zivpn.service udp-custom.service badvpn-udpgw.service \
            udpgw.service slowdns.service ragnar-wsproxy.service ragnar-landing.service ragnar-web.service; do
    registered "/etc/systemd/system/$unit" || continue
    managed_units+=("$unit")
    stop_unit "$unit"
    systemctl disable "$unit" 2>/dev/null || true
done
if registered /etc/default/dropbear; then stop_unit dropbear; fi
# A Cloudflare tunnel installed from the panel menu would otherwise keep
# publishing this server after the panel is gone.
remove_cloudflared_service() {
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared service uninstall >/dev/null 2>&1 || true
    fi
    systemctl disable --now cloudflared cloudflared-update.timer 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflared.service \
          /etc/systemd/system/cloudflared-update.service \
          /etc/systemd/system/cloudflared-update.timer
}
if installed_by_ragnar cloudflared-service && ! sister_panel_present; then
    remove_cloudflared_service || die "Cannot remove cloudflared tunnel service; state retained."
fi

# Remove only firewall rules carrying Ragnar's ownership comments. Untagged
# rules are left alone because they may be shared with another panel or host
# firewall. This covers both new-panel NAT/UFW rules and the SlowDNS rules.
delete_rule() {
    local binary="$1" table="$2" chain="$3"; shift 3
    command -v "$binary" >/dev/null 2>&1 || return 0
    while "$binary" -t "$table" -D "$chain" "$@" 2>/dev/null; do :; done
}
delete_rule iptables nat PREROUTING -p tcp --dport 8446 -m comment --comment ragnar-panel -j REDIRECT --to-ports 10006
delete_rule iptables nat PREROUTING -p udp --dport 6000:19999 -m comment --comment ragnar-panel -j REDIRECT --to-ports 5667
delete_rule iptables nat PREROUTING -p udp --dport 20000:65535 -m comment --comment ragnar-panel -j REDIRECT --to-ports 36712
if [ -r "$STATE_DIR/nat-interface" ]; then
    IFS= read -r out_if < "$STATE_DIR/nat-interface" || out_if=""
    if [ -n "${out_if:-}" ]; then
        delete_rule iptables nat POSTROUTING -o "$out_if" -m comment --comment ragnar-panel -j MASQUERADE
    fi
fi
for spec in "tcp 22" "tcp 80" "tcp 443" "tcp 109" "tcp 143" \
            "tcp 53" "udp 53" "udp 5667" "udp 36712" "tcp 8446" "tcp 2053"; do
    set -- $spec
    delete_rule iptables filter ufw-user-input -p "$1" --dport "$2" \
        -m comment --comment ragnar-panel -j ACCEPT
done
for port in 53 5300; do
    delete_rule iptables filter INPUT -p udp --dport "$port" \
        -m comment --comment ragnar-slowdns -j ACCEPT
    if command -v ip6tables >/dev/null 2>&1; then
        delete_rule ip6tables filter INPUT -p udp --dport "$port" \
            -m comment --comment ragnar-slowdns -j ACCEPT
    fi
done
delete_rule iptables nat PREROUTING ! -d 127.0.0.0/8 -p udp --dport 53 \
    -m comment --comment ragnar-slowdns -j REDIRECT --to-ports 5300
delete_rule ip6tables nat PREROUTING ! -d ::1/128 -p udp --dport 53 \
    -m comment --comment ragnar-slowdns -j REDIRECT --to-ports 5300
# udp-custom (stopped above) inserts these untagged rules itself on every start.
if registered /etc/systemd/system/udp-custom.service && [ -f "$STATE_DIR/udp-custom-before" ]; then
    current=$(ragnar_udp_custom_rules) || die "Cannot read UDP Custom firewall rules; state retained."
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -Fqx -- "$line" "$STATE_DIR/udp-custom-before" && continue
        read -ra rule <<< "$line"
        table=filter; [ "${rule[1]}" != PREROUTING ] || table=nat
        iptables -t "$table" -D "${rule[@]:1}" || die "Cannot remove UDP Custom rule; state retained."
    done <<< "$current"
fi

# Remove UFW allowances only when the installer recorded that it added them.
if [ -r "$STATE_DIR/ufw-added" ] && command -v ufw >/dev/null 2>&1; then
    while IFS= read -r rule; do
        [ -n "$rule" ] && ufw --force delete allow "$rule" >/dev/null 2>&1 || true
    done < "$STATE_DIR/ufw-added"
fi
# Persist the live post-cleanup ruleset so administrator changes made while
# Ragnar was installed are retained. If the helper fails, fall back to the
# family-specific save commands; only then fall back to the original snapshot.
keep_live=()
save_rules() {
    local dest="$1" tmp
    tmp=$(mktemp -- "$(dirname "$dest")/.ragnar-rules.XXXXXX") || return 1
    if "$2" > "$tmp" && mv -fT -- "$tmp" "$dest"; then
        keep_live+=("$dest")
    else
        rm -f -- "$tmp"
    fi
}
if registered /etc/iptables/rules.v4 && registered /etc/iptables/rules.v6 && \
   command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1; then
    keep_live+=(/etc/iptables/rules.v4 /etc/iptables/rules.v6)
else
    if registered /etc/iptables/rules.v4 && command -v iptables-save >/dev/null; then
        mkdir -p /etc/iptables && save_rules /etc/iptables/rules.v4 iptables-save
    fi
    if registered /etc/iptables/rules.v6 && command -v ip6tables-save >/dev/null; then
        mkdir -p /etc/iptables && save_rules /etc/iptables/rules.v6 ip6tables-save
    fi
fi

# Remove only recorded lines and complete, recognizable limits blocks. Stage
# edits next to their destination so an I/O error cannot truncate a host file.
python3 - "$STATE_DIR" <<'PY' || die "Shared-file cleanup failed; state retained."
from collections import Counter
from pathlib import Path
from tempfile import TemporaryDirectory
import os
import subprocess
import sys

def replace_lines(path, old, new):
    if old == new:
        return
    target = path.resolve(strict=True)
    with TemporaryDirectory(dir=target.parent, prefix=".ragnar-restore.") as tmp:
        staged = Path(tmp) / "file"
        subprocess.run(["cp", "-a", "--", target, staged], check=True)
        staged.write_bytes(b"".join(new))
        os.replace(staged, target)

for name in ("hosts", "shells"):
    record = Path(sys.argv[1]) / (name + "-added")
    path = Path("/etc") / name
    if not record.is_file() or not path.is_file():
        continue
    added = Counter(record.read_bytes().splitlines())
    old = path.read_bytes().splitlines(keepends=True)
    new = []
    for line in old:
        key = line.rstrip(b"\r\n")
        if added[key]:
            added[key] -= 1
        else:
            new.append(line)
    replace_lines(path, old, new)
    record.unlink()  # Do not remove another occurrence on retry.

path = Path("/etc/security/limits.conf")
if path.is_file():
    limits = [b"* soft nofile 1048576", b"* hard nofile 1048576",
              b"root soft nofile 1048576", b"root hard nofile 1048576"]
    blocks = ([b"# ragnar", *limits],
              [b"# BEGIN Ragnar panel limits", *limits, b"# END Ragnar panel limits"])
    old = path.read_bytes().splitlines(keepends=True)
    keys = [line.strip() for line in old]
    new, i = [], 0
    while i < len(old):
        for block in blocks:
            if keys[i:i+len(block)] == block:
                i += len(block)
                break
        else:
            new.append(old[i])
            i += 1
    replace_lines(path, old, new)
PY

if [ -f "$BASE/db/ssh.json" ]; then
    echo "Panel SSH users:"
    users=$(python3 - "$BASE/db/ssh.json" <<'PY'
import json, re, sys
with open(sys.argv[1]) as f:
    users = json.load(f)['users']
if not isinstance(users, dict) or not all(re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]{0,31}', u) for u in users):
    sys.exit("Invalid SSH account database")
print('\n'.join(users))
PY
    ) || die "Cannot read SSH accounts; panel data retained."
    printf '%s\n' "$users"
    b=""
    read -rp "Delete these Linux accounts too? [y/N] " b || true
    if [ "$b" = y ]; then
        # userdel refuses accounts with live sessions, so end them first.
        local_uid() {
            # Force string comparison even when both names look numeric.
            awk -F: -v n="$1" '"u:" $1 == "u:" n { print $3 }' /etc/passwd
        }
        while IFS= read -r u; do
            uid=$(local_uid "$u")
            [ -n "$u" ] && [ -n "$uid" ] && [ "$uid" -ge 1000 ] && [ "$uid" != 65534 ] || continue
            for _ in 1 2 3 4 5; do
                [ "$(local_uid "$u")" = "$uid" ] || break
                pkill -KILL -U "$uid" 2>/dev/null || true
                userdel -r -- "$u" 2>/dev/null && break
                sleep 1
            done
            [ -z "$(local_uid "$u")" ] || die "Could not delete Linux account $u; panel data retained."
        done <<< "$users"
    fi
fi

if sister_panel_present; then
    # Restore pre-existing SlowDNS files; don't delete a shared key or binary
    # just because the other panel started using it after this installation.
    for path in /usr/local/bin/dnstt-server /etc/vps-panel/slowdns/{server.key,server.pub,.turbo_kcp_patched,nameserver,mtu,dns_resolver,target_port}; do
        if [ ! -s "$STATE_DIR/registered$path" ] && [ ! -e "$STATE_DIR/original$path" ] && [ ! -L "$STATE_DIR/original$path" ]; then
            keep_live+=("$path")
        fi
    done
fi
ragnar_restore_files "${keep_live[@]}" || die "Could not restore all files. Backups kept at $STATE_DIR; correct the error and retry."
rmdir /etc/systemd/system/haproxy.service.d 2>/dev/null || true

# Remove upstream components only when this installer downloaded them.
if ! sister_panel_present; then
    if installed_by_ragnar xray; then
        systemctl disable --now xray 2>/dev/null || true
        rm -rf /usr/local/bin/xray /usr/local/share/xray /usr/local/etc/xray /var/log/xray \
               /etc/systemd/system/xray.service /etc/systemd/system/xray@.service \
               /etc/systemd/system/xray.service.d /etc/systemd/system/xray@.service.d \
               /etc/logrotate.d/xray || die "Cannot remove Xray; state retained."
    fi
    if installed_by_ragnar sing-box; then
        systemctl disable --now sing-box 2>/dev/null || true
        if dpkg -s sing-box >/dev/null 2>&1; then
            dpkg --purge sing-box || die "Cannot purge sing-box; state retained."
        fi
        # The package creates this service account but its purge keeps it.
        if installed_by_ragnar sing-box-user && getent passwd sing-box >/dev/null 2>&1; then
            userdel sing-box || die "Cannot remove sing-box user; state retained."
        fi
        if installed_by_ragnar sing-box-group && getent group sing-box >/dev/null 2>&1; then
            groupdel sing-box || die "Cannot remove sing-box group; state retained."
        fi
    fi
    if installed_by_ragnar cloudflared && dpkg -s cloudflared >/dev/null 2>&1; then
        # Installing the binary does not establish ownership of a tunnel
        # configured separately by the administrator.
        if [ -e /etc/systemd/system/cloudflared.service ] || [ -L /etc/systemd/system/cloudflared.service ]; then
            echo "Leaving cloudflared installed for the remaining tunnel service."
        else
            dpkg --purge cloudflared || die "Cannot purge cloudflared; state retained."
            rmdir /etc/cloudflared 2>/dev/null || true
        fi
    fi
    if installed_by_ragnar go-1.22; then
        rm -rf /usr/local/go-1.22 || die "Cannot remove Go toolchain; state retained."
    fi
fi

# Units removed above may still be linked from *.wants directories.
for unit in "${managed_units[@]}"; do
    for link in /etc/systemd/system/*.wants/"$unit"; do
        [ -L "$link" ] && [ ! -e "$link" ] && rm -f "$link"
    done
done
systemctl daemon-reload || die "Cannot reload systemd; state retained."
for unit in "${managed_units[@]}"; do
    systemctl reset-failed "$unit" 2>/dev/null || true
done

if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi
sysctl --system >/dev/null 2>&1 || true
restore_failed=0
for unit in haproxy dropbear vnstat masterdnsvpn netfilter-persistent "${managed_units[@]}"; do
    svc=${unit%.service}
    [ -f "$STATE_DIR/services/$svc" ] || continue
    ragnar_restore_service_state "$svc" || { echo "Could not restore $svc" >&2; restore_failed=1; }
done
[ "$restore_failed" = 0 ] || die "Service restoration incomplete. Backups kept at $STATE_DIR; correct the error and retry."

rm -rf -- "$BASE" || die "Cannot remove panel files; backups kept at $STATE_DIR."
rm -rf -- "$STATE_DIR"/{registered,original,services,installed} || die "Cannot remove installer records."
rm -f -- "$STATE_DIR"/{nat-interface,udp-custom-before,ufw-added,shells-added,hosts-added} || die "Cannot remove installer records."
rmdir -- "$STATE_DIR" 2>/dev/null || echo "Additional files left in $STATE_DIR."
rm -rf /tmp/ragnar-update.* /tmp/ragnar-update-self.*.sh
rm -f /tmp/ragnar-certbot.log /tmp/ragnar-slowdns-build.log /var/lock/ragnar-update.lock
rmdir /etc/vps-panel/slowdns /etc/vps-panel 2>/dev/null || true
# Created empty by the installer / cloudflared even when nothing else was kept.
rmdir /usr/local/etc/xray /usr/local/etc/cloudflared 2>/dev/null || true
echo "Ragnar Panel removed; pre-existing managed files and service states were restored where recorded."
echo "Required system packages, components that existed before Ragnar, and any shared"
echo "/etc/vps-panel SlowDNS state still used by the sister panel were left in place."
echo "Bye - @farisbazed / https://t.me/ragnaresim"
