#!/usr/bin/env bash
# Linux integration test: only the disposable chroot can see the uninstaller's
# absolute paths. Real host services, accounts and firewall are never used.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
box=$(mktemp -d)
trap 'rm -rf -- "$box"' EXIT
unshare --user --map-root-user --mount --net --pid --fork bash -eu -s -- "$box" "$repo" <<'SANDBOX'
box=$1 repo=$2
mkdir -p "$box/usr"
for path in /usr/bin /usr/lib /usr/lib64 /bin /lib /lib64; do
    if [ -L "$path" ]; then
        ln -s "$(readlink "$path")" "$box$path"
        continue
    fi
    [ -d "$path" ] || continue
    mkdir -p "$box$path"
    mount --bind "$path" "$box$path"
    mount -o remount,bind,ro "$box$path"
done
mkdir -p "$box"/{dev,etc/alternatives,mock,tmp,test/core}
touch "$box/dev/null"
mount --bind /dev/null "$box/dev/null"
ln -s "$(readlink -f "$(command -v awk)")" "$box/etc/alternatives/awk"
cp "$repo/uninstall.sh" "$box/test/"
cp "$repo/core/install-state.sh" "$box/test/core/"
chroot "$box" /usr/bin/env -i PATH=/mock:/usr/bin /bin/bash -eu -s <<'TEST'
export RAGNAR_STATE_DIR=/var/lib/ragnar-panel
state=$RAGNAR_STATE_DIR
base=/etc/ragnar
source /test/core/install-state.sh
cat > /mock/mock <<'MOCK'
#!/bin/bash
cmd=${0##*/}
echo "$cmd $*" >> /calls
case "$cmd:$1" in
    systemctl:start) [ ! -f /fail-start ] ;;
    systemctl:show) echo not-found ;;
    iptables-save:*) echo 'live IPv4' ;;
    ip6tables-save:*) echo 'partial IPv6'; exit 1 ;;
    iptables:-S) cat /input-rules ;;
    iptables:-t)
        case "$*" in
            '-t nat -S PREROUTING') cat /nat-rules ;;
            '-t nat -D PREROUTING -i eth0 -p udp -m udp --dport 1:65535 -j DNAT --to-destination :36712') : > /nat-rules ;;
            *) exit 1 ;;
        esac ;;
    iptables:*|ip6tables:*|netfilter-persistent:*) exit 1 ;;
    userdel:*) sed -i "/^${*: -1}:/d" /etc/passwd ;;
    *) exit 0 ;;
esac
MOCK
chmod +x /mock/mock
for cmd in systemctl sysctl iptables ip6tables iptables-save ip6tables-save netfilter-persistent ufw dpkg pkill userdel groupdel getent; do
    ln -s mock "/mock/$cmd"
done
run() { /bin/bash /test/uninstall.sh <<< "$1"; }
reject() { if run "$1"; then echo 'Unexpected uninstall success' >&2; exit 1; fi; }
setup() {
    mkdir -p "$base"/{core,db}
    cp /test/core/install-state.sh "$base/core/"
    touch "$base/core/ragnar.py"
    ragnar_state_init
}
run y
setup
reject y   # An empty registry cannot establish ownership.
ragnar_backup_file /etc/fixture-panel-file
mv "$state/registered" "$state/missing"
reject y
mv "$state/missing" "$state/registered"
mv "$base/core/install-state.sh" "$base/core/missing"
reject y
mv "$base/core/missing" "$base/core/install-state.sh"
run n
[ ! -e /calls ]

units=/etc/systemd/system
sd=/etc/vps-panel/slowdns
mkdir -p "$units" "$sd" /usr/local/{bin,go-1.22,share/vps-panel} /etc/{security,iptables}
for path in /usr/local/bin/menu "$sd/server.key" "$units/ragnar-web.service" "$units/udp-custom.service" "$units/ragnar-check.service"; do
    ragnar_backup_file "$path"
    echo new > "$path"
done
# An existing installation that predates checker activity snapshots does
# not acquire a bogus baseline from the running panel on its next install.
ragnar_capture_service_state ragnar-check
[ ! -e "$state/services/ragnar-check" ]
ln -s original-menu /usr/local/bin/ragnar
ragnar_backup_file /usr/local/bin/ragnar
rm /usr/local/bin/ragnar; touch /usr/local/bin/ragnar
echo admin > "$units/xray.service"
chmod 640 "$units/xray.service"
ragnar_backup_file "$units/xray.service"
: > "$state/registered$units/xray.service"  # existing (empty-marker) state format
echo panel > "$units/xray.service"
echo 'not managed' > "$units/xray.timer"
echo 'not managed' > /usr/local/bin/zivpn
printf 'enabled-runtime\nactive\n' > "$state/services/xray"
printf 'not-found\ninactive\n' > "$state/services/ragnar-web"
ragnar_mark_installed go-1.22
ragnar_mark_installed cloudflared-service
touch "$units/cloudflared.service"
touch "$state/admin-note"
echo '-A INPUT -p udp -m udp --dport 36712 -j ACCEPT' > /input-rules
touch /nat-rules
ragnar_capture_udp_custom_rules
echo '-A PREROUTING -i eth0 -p udp -m udp --dport 1:65535 -j DNAT --to-destination :36712' > /nat-rules
for f in /etc/iptables/rules.v{4,6}; do
    echo 'before Ragnar' > "$f"; ragnar_backup_file "$f"; echo panel > "$f"
done
printf '127.0.0.1 localhost\n127.0.1.1 host\n127.0.1.1 host\n' > /etc/hosts
echo '127.0.1.1 host' > "$state/hosts-added"
printf '/bin/bash\n/bin/panel\n' > /etc/shells
echo /bin/panel > "$state/shells-added"
echo '22/tcp' > "$state/ufw-added"
printf '# BEGIN Ragnar panel limits\nadmin soft nofile 4000\n' > /etc/security/limits.conf
echo '{"users":{"sample":{},"root":{},"system":{},"001":{}}}' > "$base/db/ssh.json"
printf 'root:x:0:0::/:\nsystem:x:99:99::/:\nsample:x:2001:2001::/:\n1:x:2002:2002::/:\n' > /etc/passwd

# Retry after a destination conflict, then a systemd failure.
rm /usr/local/bin/menu; mkdir /usr/local/bin/menu
reject $'y\nn'
[ -d /usr/local/bin/menu ]
[ -f "$state/original$units/xray.service" ]
rmdir /usr/local/bin/menu
touch /fail-start
reject $'y\nn'
[ -f "$base/db/ssh.json" ]
[ -f "$state/original/etc/iptables/rules.v4" ]
! grep '^userdel ' /calls || exit 1
rm /fail-start
run $'y\ny'
[ ! -e "$base" ]
[ ! -d "$state/registered" ]
[ -f "$state/admin-note" ]
[ "$(cat "$units/xray.service")" = admin ]
[ "$(stat -c %a "$units/xray.service")" = 640 ]
[ "$(readlink /usr/local/bin/ragnar)" = original-menu ]
[ ! -e /usr/local/bin/menu ]
[ ! -e "$units/ragnar-web.service" ]
[ ! -e "$units/ragnar-check.service" ]
[ "$(cat "$units/xray.timer")" = 'not managed' ]
[ "$(cat /usr/local/bin/zivpn)" = 'not managed' ]
[ "$(cat "$sd/server.key")" = new ]
[ -d /usr/local/go-1.22 ]
[ -e "$units/cloudflared.service" ]
[ ! -s /nat-rules ]
if grep -Fqx 'iptables -t filter -D INPUT -p udp -m udp --dport 36712 -j ACCEPT' /calls; then exit 1; fi
[ "$(cat /etc/iptables/rules.v4)" = 'live IPv4' ]
[ "$(cat /etc/iptables/rules.v6)" = 'before Ragnar' ]
[ "$(grep -cxF '127.0.1.1 host' /etc/hosts)" = 1 ]
[ "$(cat /etc/shells)" = /bin/bash ]
grep -qxF 'admin soft nofile 4000' /etc/security/limits.conf
grep -qxF 'systemctl enable --runtime xray' /calls
grep -qxF 'ufw --force delete allow 22/tcp' /calls
[ "$(grep '^userdel ' /calls)" = 'userdel -r -- sample' ]
[ "$(grep '^pkill ' /calls)" = 'pkill -KILL -U 2001' ]
before=$(wc -l < /calls); run y; [ "$before" = "$(wc -l < /calls)" ]

# Without the sister panel, remove the marked toolchain and new shared file;
# a pre-existing key still comes back, and unmarked components are untouched.
rmdir /usr/local/share/vps-panel
setup
ragnar_mark_installed go-1.22
ragnar_mark_installed cloudflared
ragnar_mark_installed sing-box
ragnar_backup_file "$sd/server.pub"; echo new > "$sd/server.pub"
ragnar_backup_file "$sd/server.key"; echo changed > "$sd/server.key"
touch /usr/local/bin/xray
run y
[ ! -e /usr/local/go-1.22 ]
[ ! -e "$sd/server.pub" ]
[ "$(cat "$sd/server.key")" = new ]
[ -f /usr/local/bin/xray ]
[ -f "$units/cloudflared.service" ]
if grep -Fqx 'dpkg --purge cloudflared' /calls; then exit 1; fi
grep -Fqx 'dpkg --purge sing-box' /calls
if grep -Eq '(userdel|groupdel) sing-box$' /calls; then exit 1; fi

# A clean, fully owned component install has no dependencies to preserve.
rm "$state/admin-note"
setup
ragnar_backup_file /etc/fixture-panel-file
for component in xray cloudflared cloudflared-service sing-box sing-box-user sing-box-group; do
    ragnar_mark_installed "$component"
done
run y
[ ! -e "$state" ]
[ ! -e /usr/local/bin/xray ]
[ ! -e "$units/cloudflared.service" ]
grep -Fqx 'dpkg --purge cloudflared' /calls
grep -Fqx 'userdel sing-box' /calls
grep -Fqx 'groupdel sing-box' /calls
echo 'Isolated uninstall checks passed'
TEST
SANDBOX
