#!/bin/bash
# Ragnar VPS Management Panel - uninstaller
# Removes Ragnar-owned services/configuration and restores saved originals.
# Panel-created Linux users are listed and removed only after confirmation.
set -u
BASE="/etc/ragnar"
RAGNAR_STATE_DIR="${RAGNAR_STATE_DIR:-/var/lib/ragnar-panel}"
STATE_DIR="$RAGNAR_STATE_DIR"
HAS_STATE_HELPER=0
if [ -r "$BASE/core/install-state.sh" ]; then
    . "$BASE/core/install-state.sh"
    HAS_STATE_HELPER=1
fi

[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
echo "This removes Ragnar Panel services, configs and firewall rules."
a=""
read -rp "Continue? [y/N] " a || true
[ "$a" = y ] || exit 0

# HAProxy is the front door, so stop it before its backends. Do not change
# enablement yet: the pre-install state is restored after the files/units.
systemctl stop haproxy 2>/dev/null || true
for svc in ragnar-check.timer ragnar-watchdog.timer ragnar-check ragnar-watchdog \
           xray sing-box zivpn udp-custom badvpn-udpgw udpgw slowdns \
           ragnar-wsproxy ragnar-landing ragnar-web dropbear vnstat; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
if [ "$HAS_STATE_HELPER" -eq 0 ]; then
    systemctl disable haproxy 2>/dev/null || true
fi

# Remove leftovers from older installs too. The state helper below restores
# any pre-existing versions captured by the newer installer.
for u in ragnar-check ragnar-watchdog xray sing-box zivpn udp-custom \
         badvpn-udpgw udpgw slowdns ragnar-wsproxy ragnar-landing ragnar-web; do
    rm -f "/etc/systemd/system/$u.service" "/etc/systemd/system/$u.timer"
done

# A legacy install kept this backup beside the HAProxy config. New installs
# use the private state directory instead and restore it below.
if [ "$HAS_STATE_HELPER" -eq 0 ]; then
    if [ -f /etc/haproxy/haproxy.cfg.bak-ragnar ]; then
        mv /etc/haproxy/haproxy.cfg.bak-ragnar /etc/haproxy/haproxy.cfg
    elif [ -d /etc/haproxy ]; then
        cat > /etc/haproxy/haproxy.cfg <<'CFG'
global
    log /dev/log local0
    maxconn 2048
    daemon
defaults
    log global
    mode http
    timeout connect 5s
    timeout client 50s
    timeout server 50s
CFG
    fi
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

# Remove UFW allowances only when the installer recorded that it added them.
if [ -r "$STATE_DIR/ufw-added" ] && command -v ufw >/dev/null 2>&1; then
    while IFS= read -r rule; do
        [ -n "$rule" ] && ufw --force delete allow "$rule" >/dev/null 2>&1 || true
    done < "$STATE_DIR/ufw-added"
fi
# Persist the live post-cleanup ruleset so administrator changes made while
# Ragnar was installed are retained. If the helper fails, fall back to the
# family-specific save commands; only then fall back to the original snapshot.
SAVE_V4=0
SAVE_V6=0
if command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1; then
    SAVE_V4=1
    SAVE_V6=1
else
    mkdir -p /etc/iptables
    if command -v iptables-save >/dev/null 2>&1 && iptables-save > /etc/iptables/rules.v4; then
        SAVE_V4=1
    fi
    if command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6; then
        SAVE_V6=1
    fi
fi
if [ "$SAVE_V4" -eq 1 ]; then
    rm -f "$STATE_DIR/registered/etc/iptables/rules.v4" "$STATE_DIR/original/etc/iptables/rules.v4"
fi
if [ "$SAVE_V6" -eq 1 ]; then
    rm -f "$STATE_DIR/registered/etc/iptables/rules.v6" "$STATE_DIR/original/etc/iptables/rules.v6"
fi

# Remove exactly the additions made to the shared files by the old installer.
if [ -r "$STATE_DIR/shells-added" ] && [ -f /etc/shells ]; then
    python3 - "$STATE_DIR/shells-added" /etc/shells <<'PY'
from collections import Counter
import sys
added = Counter(line.rstrip("\n") for line in open(sys.argv[1], encoding="utf-8"))
path = sys.argv[2]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
with open(path, "w", encoding="utf-8") as f:
    for line in lines:
        key = line.rstrip("\n")
        if added[key]:
            added[key] -= 1
        else:
            f.write(line)
PY
fi
if [ -r "$STATE_DIR/hosts-added" ] && [ -f /etc/hosts ]; then
    python3 - "$STATE_DIR/hosts-added" /etc/hosts <<'PY'
from collections import Counter
import sys
added = Counter(line.rstrip("\n") for line in open(sys.argv[1], encoding="utf-8"))
path = sys.argv[2]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
with open(path, "w", encoding="utf-8") as f:
    for line in lines:
        key = line.rstrip("\n")
        if added[key]:
            added[key] -= 1
        else:
            f.write(line)
PY
fi
python3 - <<'PY'
from pathlib import Path
p = Path('/etc/security/limits.conf')
if p.exists():
    lines = p.read_text().splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        if lines[i].strip() == '# BEGIN Ragnar panel limits':
            i += 1
            while i < len(lines) and lines[i].strip() != '# END Ragnar panel limits':
                i += 1
            if i < len(lines):
                i += 1
            continue
        if (lines[i].strip() == '# ragnar' and
            [x.strip() for x in lines[i + 1:i + 5]] == [
                '* soft nofile 1048576', '* hard nofile 1048576',
                'root soft nofile 1048576', 'root hard nofile 1048576']):
            i += 5
            continue
        out.append(lines[i])
        i += 1
    p.write_text(''.join(out))
PY

# Compatibility cleanup for legacy installs; shared SlowDNS data in
# /etc/vps-panel/slowdns is deliberately retained for the sister panel.
rm -f /etc/sysctl.d/99-ragnar-tuning.conf /etc/ssh/sshd_config.d/60-ragnar.conf
rm -f /usr/local/bin/menu /usr/local/bin/ragnar /usr/local/bin/zivpn \
      /usr/local/bin/udp-custom /usr/local/bin/badvpn-udpgw

if [ -f "$BASE/db/ssh.json" ]; then
    echo "Panel SSH users:"
    python3 -c "import json;print('\n'.join(json.load(open('$BASE/db/ssh.json'))['users']))" 2>/dev/null
    b=""
    read -rp "Delete these Linux accounts too? [y/N] " b || true
    if [ "$b" = y ]; then
        python3 -c "import json;print('\n'.join(json.load(open('$BASE/db/ssh.json'))['users']))" \
            | while IFS= read -r u; do [ -n "$u" ] && userdel -r -- "$u" 2>/dev/null || true; done
    fi
fi

if [ "$HAS_STATE_HELPER" -eq 1 ]; then
    ragnar_restore_files || echo "Warning: some original files could not be restored; see messages above."
else
    rm -f /etc/systemd/system/haproxy.service.d/10-ragnar.conf
fi
rmdir /etc/systemd/system/haproxy.service.d 2>/dev/null || true
systemctl daemon-reload

if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi
sysctl --system >/dev/null 2>&1 || true
if [ "$HAS_STATE_HELPER" -eq 1 ]; then
    for svc in haproxy dropbear vnstat masterdnsvpn netfilter-persistent xray sing-box zivpn udp-custom badvpn-udpgw udpgw \
               slowdns ragnar-wsproxy ragnar-landing ragnar-check.timer \
               ragnar-watchdog.timer ragnar-web; do
        ragnar_restore_service_state "$svc" || true
    done
else
    systemctl disable --now dropbear 2>/dev/null || true
    if [ -f /etc/haproxy/haproxy.cfg ]; then
        systemctl enable --now haproxy 2>/dev/null || true
    fi
fi

rm -rf "$BASE"
[ "$HAS_STATE_HELPER" -eq 0 ] || rm -rf "$STATE_DIR"
echo "Ragnar Panel removed; pre-existing managed files and service states were restored where recorded."
echo "Shared /etc/vps-panel SlowDNS state, upstream binaries, and required system packages were left in place."
echo "Bye - @farisbazed / https://t.me/ragnaresim"
