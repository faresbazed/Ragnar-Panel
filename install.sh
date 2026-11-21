#!/bin/bash
# =====================================================================
# Ragnar VPS Management Panel - installer
# Telegram : @farisbazed      Channel : https://t.me/ragnaresim
#
# Usage (fresh Ubuntu 22.04/24.04 or Debian 11/12, as root):
#   git clone <this repo> && cd ragnar-vps-panel
#   sudo bash install.sh
#
# Non-interactive:
#   RAGNAR_DOMAIN=vpn.example.com RAGNAR_NS=ns.example.com sudo -E bash install.sh
# =====================================================================
set -u
PANEL="Ragnar VPS Management Panel"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="/etc/ragnar"
log()  { echo -e "\033[96m[RAGNAR]\033[0m $*"; }
warn() { echo -e "\033[93m[RAGNAR]\033[0m $*"; }
die()  { echo -e "\033[91m[RAGNAR] $*\033[0m"; exit 1; }

[ "$(id -u)" = 0 ] || die "Run as root: sudo bash install.sh"
. "$SRC/core/install-state.sh" || die "Cannot load install-state helpers"
ragnar_state_init || die "Cannot create installer state directory"
# Snapshot service state before apt can start newly installed daemons. On a
# reinstall, the first-install snapshot is retained rather than overwritten.
for svc in haproxy dropbear vnstat netfilter-persistent masterdnsvpn xray sing-box zivpn udp-custom badvpn-udpgw udpgw \
           slowdns ragnar-wsproxy ragnar-landing ragnar-check.timer \
           ragnar-watchdog.timer ragnar-web; do
    ragnar_capture_service_state "$svc" || warn "Could not record prior state for $svc"
done
# iptables-persistent saves the whole host ruleset; keep the existing saved
# rules so uninstall can restore them instead of leaving Ragnar's snapshot.
ragnar_backup_file /etc/iptables/rules.v4 || die "Cannot preserve existing IPv4 firewall rules"
ragnar_backup_file /etc/iptables/rules.v6 || die "Cannot preserve existing IPv6 firewall rules"
. /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release"
case " $ID ${ID_LIKE:-} " in
    *ubuntu*|*debian*) : ;;
    *) warn "Tested on Ubuntu/Debian - continuing anyway" ;;
esac

IS_UPDATE=0
if [ "${RAGNAR_UPDATE:-0}" = "1" ] || [ -n "${RAGNAR_UPDATE_COPY:-}" ] || [ -f "$BASE/core/ragnar.py" ]; then
    IS_UPDATE=1
fi

# ---------------------------------------------------------------------
# Install / replace all panel code files FIRST so updates always land
# even if a third-party apt repository or optional network fetch fails.
# ---------------------------------------------------------------------
mkdir -p "$BASE"/{db,core,certs,xray,sing-box,zivpn,udp,slowdns,web}
rm -rf "$BASE/core/__pycache__" "$BASE/web/__pycache__"
install -m 755 "$SRC/core/ragnar.py"        "$BASE/core/ragnar.py"
install -m 755 "$SRC/core/checker.py"       "$BASE/core/checker.py"
install -m 755 "$SRC/core/wsproxy.py"       "$BASE/core/wsproxy.py"
install -m 755 "$SRC/core/install-state.sh" "$BASE/core/install-state.sh"
install -m 755 "$SRC/core/watchdog.sh"      "$BASE/core/watchdog.sh"
install -m 755 "$SRC/core/slowdns-setup.sh" "$BASE/core/slowdns-setup.sh"
install -m 755 "$SRC/core/update.sh"        "$BASE/core/update.sh"
install -m 755 "$SRC/menu.sh"               "$BASE/menu.sh"
install -m 755 "$SRC/uninstall.sh"          "$BASE/uninstall.sh"
install -m 755 "$SRC/web/webpanel.py"       "$BASE/web/webpanel.py"
ragnar_backup_file /usr/local/bin/menu || die "Cannot preserve existing menu command"
ragnar_backup_file /usr/local/bin/ragnar || die "Cannot preserve existing ragnar command"
rm -f /usr/local/bin/menu /usr/local/bin/ragnar
ln -s "$BASE/menu.sh" /usr/local/bin/menu
ln -s "$BASE/menu.sh" /usr/local/bin/ragnar

# Record the installed code version (from git checkout or GitHub tarball folder name).
if command -v git >/dev/null 2>&1 && git -C "$SRC" rev-parse HEAD >/dev/null 2>&1; then
    printf '%s %s\n' "$(git -C "$SRC" rev-parse HEAD)" "$(date -Is)" > "$BASE/version"
else
    _src_base="$(basename "$SRC")"
    case "$_src_base" in
        *-*[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
            _sha="${_src_base##*-}"
            if [ "${#_sha}" -ge 7 ]; then
                printf '%s %s\n' "$_sha" "$(date -Is)" > "$BASE/version"
            fi
            ;;
    esac
fi

# ---------------------------------------------------------------------
# Questions (never prompt interactively during an in-place update)
# ---------------------------------------------------------------------
DOMAIN="${RAGNAR_DOMAIN:-}"
NS="${RAGNAR_NS:-}"
if [ "$IS_UPDATE" = 1 ]; then
    if [ -z "$DOMAIN" ] && [ -f "$BASE/settings.json" ] && command -v python3 >/dev/null 2>&1; then
        DOMAIN=$(python3 -c 'import json; print((json.load(open("/etc/ragnar/settings.json")).get("domain") or "").strip())' 2>/dev/null || true)
    fi
    if [ -z "$DOMAIN" ] && [ -f "$BASE/domain" ]; then
        DOMAIN=$(head -n1 "$BASE/domain" 2>/dev/null | tr -d '\r\n' || true)
    fi
    if [ -z "$NS" ] && [ -f "$BASE/settings.json" ] && command -v python3 >/dev/null 2>&1; then
        NS=$(python3 -c 'import json; print((json.load(open("/etc/ragnar/settings.json")).get("ns") or "").strip())' 2>/dev/null || true)
    fi
else
    if [ -z "$DOMAIN" ] && [ -t 0 ]; then
        read -rp "Domain pointed at this VPS (blank = use IP, self-signed cert): " DOMAIN
    fi
    if [ -z "$NS" ] && [ -t 0 ]; then
        read -rp "SlowDNS nameserver (e.g. ns.yourdomain.com, blank = skip SlowDNS NS): " NS
    fi
fi

PUBIP=$(curl -s4 --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')
HOST_FOR_LINKS="${DOMAIN:-$PUBIP}"
log "Installing $PANEL for host $HOST_FOR_LINKS (IP $PUBIP)"

# ---------------------------------------------------------------------
# Packages + tuning
# ---------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
# Silence "sudo: unable to resolve host" on hosts without a hosts entry.
if ! grep -q " $(hostname)" /etc/hosts 2>/dev/null; then
    printf '127.0.1.1 %s\n' "$(hostname)" >> /etc/hosts
    printf '127.0.1.1 %s\n' "$(hostname)" >> "$RAGNAR_STATE_DIR/hosts-added"
fi

NEED_APT=1
if [ "$IS_UPDATE" = 1 ]; then
    NEED_APT=0
    for req_bin in curl wget tar jq python3 haproxy dropbear vnstat iptables socat openssl; do
        if ! command -v "$req_bin" >/dev/null 2>&1; then
            NEED_APT=1
            break
        fi
    done
fi

if [ "$NEED_APT" = 1 ]; then
    # Repair a half-finished dpkg state first (a common fresh-VPS landmine:
    # every apt install then fails with "dpkg was interrupted").
    dpkg --configure -a || [ "$IS_UPDATE" = 1 ] || die "dpkg configuration failed; fix the package-manager errors above and re-run install.sh"
    apt-get -o DPkg::Lock::Timeout=60 install -f -y || [ "$IS_UPDATE" = 1 ] || die "apt dependency repair failed; fix the errors above and re-run install.sh"
    apt-get -o DPkg::Lock::Timeout=60 update || [ "$IS_UPDATE" = 1 ] || die "apt package-index update failed; check network/repository configuration and re-run install.sh"
    apt-get -o DPkg::Lock::Timeout=60 install -y curl wget unzip tar jq python3 haproxy dropbear \
        openssh-server vnstat iptables iptables-persistent socat openssl cron \
        certbot iproute2 net-tools procps ca-certificates gnupg \
        || [ "$IS_UPDATE" = 1 ] || die "Package installation failed - fix apt (try: sudo dpkg --configure -a) and re-run install.sh"
fi

# Keep a clean persistence baseline before adding panel firewall rules. The
# package may create rules.v4/rules.v6 during its own setup, so capture those
# generated defaults too when no file existed before this installation.
for family in 4 6; do
    rules_file="/etc/iptables/rules.v${family}"
    original_file="$RAGNAR_STATE_DIR/original/etc/iptables/rules.v${family}"
    if [ ! -e "$original_file" ] && [ ! -L "$original_file" ] && [ ! -e "$rules_file" ]; then
        mkdir -p /etc/iptables
        save_bin=iptables-save
        [ "$family" = 4 ] || save_bin=ip6tables-save
        if command -v "$save_bin" >/dev/null 2>&1; then
            tmp="${rules_file}.tmp.$$"
            if "$save_bin" > "$tmp"; then mv -f "$tmp" "$rules_file"; else rm -f "$tmp"; fi
        fi
    fi
    ragnar_capture_generated_file "$rules_file" || warn "Could not preserve generated firewall baseline: $rules_file"
done
# NOTE: there is no 'badvpn' package in Ubuntu 24.04 - udpgw is fetched
# as the upstream prebuilt binary in the UDP Custom section below.
for bin in haproxy python3 openssl; do
    command -v "$bin" >/dev/null || die "$bin is missing after apt install - aborting before half-configuring the box"
done
# Download a binary atomically: fetch to a temp file in the same
# directory, then rename into place. A plain "wget -O <dest>" truncates
# the target and fails with "Text file busy" whenever the old binary is
# still running - the classic re-run-the-installer-over-a-live-panel
# failure that used to skip udp-custom and SlowDNS entirely.
fetch_bin() {
    local url="$1" dest="$2" tmp="${2}.tmp.$$"
    if wget -q "$url" -O "$tmp"; then
        chmod +x "$tmp" && mv -f "$tmp" "$dest"
    else
        rm -f "$tmp"; return 1
    fi
}
# Re-installing over a live panel: stop the services whose binaries are
# about to be replaced (all units are restarted at the end).
if [ "$IS_UPDATE" = 0 ]; then
    for u in zivpn udp-custom badvpn-udpgw udpgw slowdns xray sing-box ragnar-wsproxy; do
        systemctl stop "$u" 2>/dev/null || true
    done
fi
mkdir -p /etc/haproxy

ragnar_backup_file /etc/sysctl.d/99-ragnar-tuning.conf || die "Cannot preserve existing sysctl configuration"
install -m 644 "$SRC/configs/99-ragnar-tuning.conf" /etc/sysctl.d/99-ragnar-tuning.conf
sysctl --system >/dev/null 2>&1 || true
if ! grep -Fq '# BEGIN Ragnar panel limits' /etc/security/limits.conf; then
    if ! grep -Fq '# ragnar' /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<'EOF'
# BEGIN Ragnar panel limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
# END Ragnar panel limits
EOF
    fi
fi
systemctl enable vnstat >/dev/null 2>&1 || true

[ -n "$PUBIP" ] && echo "$PUBIP" > "$BASE/host"
if [ ! -s "$BASE/isp" ]; then
    ISP_NAME=$(curl -s --max-time 4 "https://ipinfo.io/org" 2>/dev/null | sed 's/^AS[0-9]* //' || true)
    [ -n "$ISP_NAME" ] && echo "$ISP_NAME" > "$BASE/isp"
fi
[ -n "$DOMAIN" ] && echo "$DOMAIN" > "$BASE/domain"
python3 - "$DOMAIN" "$NS" <<'PY'
import json, os, sys
p = "/etc/ragnar/settings.json"
s = json.load(open(p)) if os.path.exists(p) else {}
if sys.argv[1]: s["domain"] = sys.argv[1]
if sys.argv[2]: s["ns"] = sys.argv[2]
json.dump(s, open(p, "w"), indent=2)
PY

# ---------------------------------------------------------------------
# Certificates (refresh from Let's Encrypt before preserving local certs)
# ---------------------------------------------------------------------
if [ -n "$DOMAIN" ] && [ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] && \
        [ -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ] && \
        openssl x509 -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1; then
    bash "$SRC/core/cert-deploy.sh" "/etc/letsencrypt/live/$DOMAIN" || die "Cannot deploy Let's Encrypt certificate"
elif [ "$IS_UPDATE" = 1 ] && [ -s "$BASE/certs/fullchain.pem" ] && [ -s "$BASE/certs/privkey.pem" ]; then
    log "Preserving existing TLS certificates"
else
    CERT_OK=0
    if [ -n "$DOMAIN" ]; then
        DIP=$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1)
        if [ "$DIP" = "$PUBIP" ]; then
            systemctl stop haproxy 2>/dev/null || true
            : > /tmp/ragnar-certbot.log
            if certbot certonly --standalone --non-interactive --agree-tos \
                    -m "admin@$DOMAIN" -d "$DOMAIN" -d "anytls.$DOMAIN" \
                    >>/tmp/ragnar-certbot.log 2>&1; then
                CERT_OK=1; log "Let's Encrypt certificate installed (domain + anytls subdomain)"
            elif certbot certonly --standalone --non-interactive --agree-tos \
                    -m "admin@$DOMAIN" -d "$DOMAIN" >>/tmp/ragnar-certbot.log 2>&1; then
                CERT_OK=1
                warn "Let's Encrypt certificate installed for $DOMAIN only."
                warn "Add an A record  anytls.$DOMAIN -> $PUBIP  and re-run install.sh"
                warn "so the AnyTLS name is covered too (AnyTLS needs that record anyway)."
            else
                warn "certbot failed - last lines of /tmp/ragnar-certbot.log:"
                tail -n 8 /tmp/ragnar-certbot.log 2>/dev/null | sed 's/^/    /'
            fi
            if [ "$CERT_OK" = 1 ]; then
                bash "$SRC/core/cert-deploy.sh" "/etc/letsencrypt/live/$DOMAIN" || die "Cannot deploy Let's Encrypt certificate"
            fi
        fi
    fi
    if [ "$CERT_OK" = 0 ]; then
        warn "Using a self-signed certificate (clients: allow insecure / set SNI to the host)"
        openssl req -x509 -newkey rsa:2048 -keyout "$BASE/certs/privkey.pem" \
            -out "$BASE/certs/fullchain.pem" -days 3650 -nodes \
            -subj "/CN=$HOST_FOR_LINKS" \
            -addext "subjectAltName=DNS:$HOST_FOR_LINKS,IP:$PUBIP" 2>/dev/null
    fi
fi
cat "$BASE/certs/fullchain.pem" "$BASE/certs/privkey.pem" > "$BASE/certs/haproxy.pem"
chmod 600 "$BASE/certs/"*.pem "$BASE/certs/haproxy.pem"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
ragnar_backup_file /etc/letsencrypt/renewal-hooks/deploy/ragnar-cert-deploy || die "Cannot preserve existing certificate hook"
install -m 755 "$SRC/core/cert-deploy.sh" /etc/letsencrypt/renewal-hooks/deploy/ragnar-cert-deploy
# ZIVPN certificate (its own format/names)
if [ ! -s "$BASE/certs/zivpn.crt" ] || [ ! -s "$BASE/certs/zivpn.key" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$BASE/certs/zivpn.key" \
        -out "$BASE/certs/zivpn.crt" -days 3650 -nodes -subj "/CN=$HOST_FOR_LINKS" 2>/dev/null
fi

# ---------------------------------------------------------------------
# SSH: OpenSSH 22 + Dropbear 109 (backends only; front door is HAProxy)
# ---------------------------------------------------------------------
mkdir -p /etc/ssh/sshd_config.d
ragnar_backup_file /etc/ssh/sshd_config.d/60-ragnar.conf || die "Cannot preserve existing SSH configuration"
cat > /etc/ssh/sshd_config.d/60-ragnar.conf <<'EOF'
PasswordAuthentication yes
PermitTunnel yes
AllowTcpForwarding yes
GatewayPorts yes
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 10
MaxSessions 100
EOF
ragnar_backup_file /etc/default/dropbear || die "Cannot preserve existing Dropbear configuration"
cat > /etc/default/dropbear <<'EOF'
NO_START=0
DROPBEAR_PORT=109
DROPBEAR_EXTRA_ARGS="-p 143 -W 65536"
DROPBEAR_BANNER=""
DROPBEAR_RECEIVE_WINDOW=1048576
EOF
# Panel accounts are forwarding-only (shell /bin/false). Dropbear refuses
# logins for shells missing from /etc/shells ("User X has invalid shell,
# rejected") - and Debian's /etc/shells does NOT list /bin/false while
# Ubuntu's does, so panel users could never log in on Debian. Add both
# spellings on every distro.
for sh in /bin/false /usr/bin/false; do
    if ! grep -Fqx "$sh" /etc/shells 2>/dev/null; then
        printf '%s\n' "$sh" >> "$RAGNAR_STATE_DIR/shells-added"
        echo "$sh" >> /etc/shells
    fi
done
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
systemctl enable dropbear 2>/dev/null || true
# "enable --now" alone is NOT enough on Debian: the dropbear package's
# postinst starts the sysv-generated unit at apt-install time, while
# /etc/default/dropbear still holds the package default NO_START=1, so
# the unit sits in "active (exited)" with no daemon listening and --now
# is a no-op. Restart it now that the config above is in place.
systemctl restart dropbear 2>/dev/null || service dropbear restart 2>/dev/null || true

# Landing page (harmless "It works" page for plain HTTPS visitors on 443)
mkdir -p "$BASE/www"
cat > "$BASE/www/index.html" <<'EOF'
<html><head><title>Welcome</title></head><body><h3>It works.</h3></body></html>
EOF
ragnar_backup_file /etc/systemd/system/ragnar-landing.service || die "Cannot preserve existing landing-page service"
cat > /etc/systemd/system/ragnar-landing.service <<'EOF'
[Unit]
Description=Ragnar landing page
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 10080 --bind 127.0.0.1 --directory /etc/ragnar/www
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

# SSH WebSocket proxy service
ragnar_backup_file /etc/systemd/system/ragnar-wsproxy.service || die "Cannot preserve existing WebSocket service"
cat > /etc/systemd/system/ragnar-wsproxy.service <<'EOF'
[Unit]
Description=Ragnar SSH WebSocket proxy
After=network.target dropbear.service
[Service]
ExecStart=/usr/bin/python3 /etc/ragnar/core/wsproxy.py
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------
# HAProxy front door (owns 80 + 443 - see configs/haproxy.cfg)
# ---------------------------------------------------------------------
ragnar_backup_file /etc/haproxy/haproxy.cfg || die "Cannot preserve existing HAProxy configuration"
install -m 644 "$SRC/configs/haproxy.cfg" /etc/haproxy/haproxy.cfg
mkdir -p /run/haproxy /etc/systemd/system/haproxy.service.d
ragnar_backup_file /etc/systemd/system/haproxy.service.d/10-ragnar.conf || die "Cannot preserve existing HAProxy override"
cat > /etc/systemd/system/haproxy.service.d/10-ragnar.conf <<'EOF'
[Service]
LimitNOFILE=1048576
EOF
systemctl daemon-reload
haproxy -c -f /etc/haproxy/haproxy.cfg || die "HAProxy config invalid - aborting"
# restart, not just enable --now: on a re-install HAProxy may already be
# running with the previous config in memory (observed live 2026-11-13:
# the new /panel routing sat on disk while the old process kept serving
# the old config, and the web panel 404'd until a manual restart).
systemctl enable haproxy
systemctl restart haproxy

# ---------------------------------------------------------------------
# Xray (VLESS / VMESS / Trojan / SSWS over WS) + sing-box (AnyTLS)
# ---------------------------------------------------------------------
if ! command -v xray >/dev/null; then
    if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
        ragnar_mark_installed xray || warn "Could not record the Xray install for uninstall"
    else
        warn "Xray install failed - install it manually, then run: menu -> Tools -> Restart ALL"
    fi
fi
# The upstream Xray installer plants /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf,
# which overrides ExecStart to /usr/local/etc/xray/config.json. The panel writes users only to
# /etc/ragnar/xray/config.json, so Xray kept serving the install-time copy (zero users once anyone was
# added) - observed live 2026-11-15 on the trial VPS ("invalid request user id"). Remove the drop-in
# (also on reinstalls, where xray already exists and the installer above is skipped) so the panel's
# own xray.service below (ExecStart=/etc/ragnar/xray/config.json) wins. daemon-reload runs later
# in this script, before the services are enabled.
ragnar_backup_file /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf || die "Cannot preserve Xray service drop-in"
rm -f /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf
rmdir /etc/systemd/system/xray.service.d 2>/dev/null || true
mkdir -p /usr/local/etc/xray
if ! command -v sing-box >/dev/null; then
    if bash -c "$(curl -fsSL https://sing-box.app/install.sh)"; then
        ragnar_mark_installed sing-box || warn "Could not record the sing-box install for uninstall"
    else
        warn "sing-box install failed - AnyTLS will stay offline until it is installed"
    fi
fi
ragnar_backup_file /etc/systemd/system/xray.service || die "Cannot preserve existing Xray service"
cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray (Ragnar)
After=network.target
[Service]
ExecStart=/usr/local/bin/xray run -config /etc/ragnar/xray/config.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
User=root
[Install]
WantedBy=multi-user.target
EOF
SINGBOX_BIN=$(command -v sing-box || echo /usr/local/bin/sing-box)
ragnar_backup_file /etc/systemd/system/sing-box.service || die "Cannot preserve existing sing-box service"
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box AnyTLS (Ragnar)
After=network.target
[Service]
ExecStart=$SINGBOX_BIN run -c /etc/ragnar/sing-box/config.json
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
# AnyTLS direct fallback port (8446 -> sing-box backend, simple redirect)
RAGNAR_FW_COMMENT=ragnar-panel
if ! iptables -t nat -C PREROUTING -p tcp --dport 8446 -j REDIRECT --to-ports 10006 2>/dev/null && \
   ! iptables -t nat -C PREROUTING -p tcp --dport 8446 -m comment --comment "$RAGNAR_FW_COMMENT" -j REDIRECT --to-ports 10006 2>/dev/null; then
    iptables -t nat -A PREROUTING -p tcp --dport 8446 -m comment --comment "$RAGNAR_FW_COMMENT" -j REDIRECT --to-ports 10006
fi

# ---------------------------------------------------------------------
# UDP ZIVPN (binary: zahidbd2/udp-zivpn) - optimized
# ---------------------------------------------------------------------
ARCH=$(uname -m); [ "$ARCH" = x86_64 ] && ZARCH=amd64 || ZARCH=arm64
# Pinned upstream release (zahidbd2/udp-zivpn) - the binary is invoked as
# "zivpn server -c <config>", exactly as upstream's own installer does.
ZURL="https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-${ZARCH}"
ragnar_backup_file /usr/local/bin/zivpn || die "Cannot preserve existing ZIVPN binary"
if [ "$IS_UPDATE" = 1 ] && [ -x /usr/local/bin/zivpn ] && [ "${RAGNAR_FORCE_BINS:-0}" != "1" ]; then
    log "Keeping existing ZIVPN binary"
elif fetch_bin "$ZURL" /usr/local/bin/zivpn; then
    log "ZIVPN binary installed"
else
    warn "ZIVPN binary download failed - service created but it cannot start until /usr/local/bin/zivpn exists"
fi
ragnar_backup_file /etc/systemd/system/zivpn.service || die "Cannot preserve existing ZIVPN service"
cat > /etc/systemd/system/zivpn.service <<'EOF'
[Unit]
Description=UDP ZIVPN (Ragnar)
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/ragnar/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/ragnar/zivpn/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576
Environment=ZIVPN_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
[Install]
WantedBy=multi-user.target
EOF
# ZIVPN speed trick used by every fast panel: the client may hit any UDP
# port in 6000-19999; redirect the whole range onto the server port.
if ! iptables -t nat -C PREROUTING -p udp --dport 6000:19999 -j REDIRECT --to-ports 5667 2>/dev/null && \
   ! iptables -t nat -C PREROUTING -p udp --dport 6000:19999 -m comment --comment "$RAGNAR_FW_COMMENT" -j REDIRECT --to-ports 5667 2>/dev/null; then
    iptables -t nat -A PREROUTING -p udp --dport 6000:19999 -m comment --comment "$RAGNAR_FW_COMMENT" -j REDIRECT --to-ports 5667
fi

# ---------------------------------------------------------------------
# UDP Custom (ePro binary, checksum-verified) + badvpn-udpgw
# ---------------------------------------------------------------------
ragnar_backup_file /usr/local/bin/udp-custom || die "Cannot preserve existing UDP Custom binary"
if [ "$ARCH" = x86_64 ]; then
    if [ "$IS_UPDATE" = 1 ] && [ -x /usr/local/bin/udp-custom ] && [ "${RAGNAR_FORCE_BINS:-0}" != "1" ]; then
        log "Keeping existing udp-custom binary"
    elif fetch_bin https://raw.githubusercontent.com/http-custom/udp-custom/main/bin/udp-custom-linux-amd64 \
            /usr/local/bin/udp-custom; then
        echo "2a1b5584c7947feb5a02e847e09795751024f63ce7137a353c2b9c2a4282d636  /usr/local/bin/udp-custom" \
            | sha256sum -c - >/dev/null 2>&1 \
            || warn "udp-custom checksum differs from the pinned upstream hash - keeping the binary, verify upstream before trusting it"
        chmod +x /usr/local/bin/udp-custom
    else
        warn "udp-custom download failed"
    fi
fi
python3 - <<'PY'
import json, os
# Optimized upstream-shaped config: 80 MB receive buffer, big stream buffer,
# SSH users mirrored as passwords-auth entries (user:pass).
cfg = {"listen": ":36712", "stream_buffer": 33554432, "receive_buffer": 83886080,
       "auth": {"mode": "passwords", "config": []}}
try:
    ssh = json.load(open("/etc/ragnar/db/ssh.json"))["users"]
    cfg["auth"]["config"] = [f"{u}:{d['password']}" for u, d in ssh.items()]
except Exception:
    pass
os.makedirs("/etc/ragnar/udp", exist_ok=True)
json.dump(cfg, open("/etc/ragnar/udp/config.json", "w"), indent=2)
PY
ragnar_backup_file /etc/systemd/system/udp-custom.service || die "Cannot preserve existing UDP Custom service"
cat > /etc/systemd/system/udp-custom.service <<'EOF'
[Unit]
Description=UDP Custom by ePro Dev Team (Ragnar)
After=network.target
[Service]
WorkingDirectory=/etc/ragnar/udp
ExecStart=/usr/local/bin/udp-custom server
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
# BadVPN udpgw (the UDP gateway UDP Custom clients use for voice/games):
# a system badvpn-udpgw if one exists, else the upstream prebuilt BadVPN
# binary. Installed under its canonical name and service so it shows up
# as badvpn-udpgw everywhere (older Ragnar installs ran it as udpgw -
# migrate the binary and retire the old unit name).
ragnar_backup_file /usr/local/bin/badvpn-udpgw || die "Cannot preserve existing BadVPN binary"
ragnar_backup_file /usr/local/bin/udpgw || die "Cannot preserve existing udpgw link"
UDPGW_BIN=$(command -v badvpn-udpgw || true)
if [ -z "$UDPGW_BIN" ]; then
    if [ -x /usr/local/bin/badvpn-udpgw ]; then
        UDPGW_BIN=/usr/local/bin/badvpn-udpgw
    elif [ -x /usr/local/bin/udpgw ]; then
        cp /usr/local/bin/udpgw /usr/local/bin/badvpn-udpgw
        UDPGW_BIN=/usr/local/bin/badvpn-udpgw
    elif fetch_bin https://raw.githubusercontent.com/http-custom/udp-custom/main/module/udpgw \
            /usr/local/bin/badvpn-udpgw; then
        UDPGW_BIN=/usr/local/bin/badvpn-udpgw
    else
        warn "badvpn-udpgw download failed - UDP gateway will stay offline"
        UDPGW_BIN=/usr/local/bin/badvpn-udpgw
    fi
fi
ln -sf "$UDPGW_BIN" /usr/local/bin/udpgw
if [ -f /etc/systemd/system/udpgw.service ]; then
    ragnar_backup_file /etc/systemd/system/udpgw.service || die "Cannot preserve existing udpgw service"
    systemctl disable --now udpgw 2>/dev/null || true
    rm -f /etc/systemd/system/udpgw.service
fi
ragnar_backup_file /etc/systemd/system/badvpn-udpgw.service || die "Cannot preserve existing BadVPN service"
cat > /etc/systemd/system/badvpn-udpgw.service <<EOF
[Unit]
Description=BadVPN udpgw - UDP gateway for UDP Custom (Ragnar)
After=network.target
[Service]
ExecStart=$UDPGW_BIN --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 100
Restart=always
RestartSec=2
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
# UDP Custom clients can use any UDP port; NAT the range onto 36712
# (excluding ZIVPN's range and DNS).
if ! iptables -t nat -C PREROUTING -p udp --dport 20000:65535 -j REDIRECT --to-ports 36712 2>/dev/null && \
   ! iptables -t nat -C PREROUTING -p udp --dport 20000:65535 -m comment --comment "$RAGNAR_FW_COMMENT" -j REDIRECT --to-ports 36712 2>/dev/null; then
    iptables -t nat -A PREROUTING -p udp --dport 20000:65535 -m comment --comment "$RAGNAR_FW_COMMENT" -j REDIRECT --to-ports 36712
fi
# Outbound NAT for tunnel users
OUT_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<NF; i++) if ($i == "dev") {print $(i+1); exit}}')
if [ -n "$OUT_IF" ]; then
    printf '%s\n' "$OUT_IF" > "$RAGNAR_STATE_DIR/nat-interface"
    if ! iptables -t nat -C POSTROUTING -o "$OUT_IF" -j MASQUERADE 2>/dev/null && \
       ! iptables -t nat -C POSTROUTING -o "$OUT_IF" -m comment --comment "$RAGNAR_FW_COMMENT" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$OUT_IF" -m comment --comment "$RAGNAR_FW_COMMENT" -j MASQUERADE
    fi
else
    warn "No default IPv4 interface found; outbound NAT rule was not added"
fi

# ---------------------------------------------------------------------
# SlowDNS - the Ragnar-VPS-Management-Panel implementation (turbo
# dnstt-server: KCP NoDelay(1, 10, 2, 1) + window 1024, QueueSize
# 1024, smux 4 MB; their NAT/CF/unit code) integrated into this
# panel by core/slowdns-setup.sh: config in settings.json, keys in
# $BASE/slowdns/, their /etc/vps-panel/slowdns/ layout mirrored on
# every run. First run adopts any existing SlowDNS identity found
# in /etc/vps-panel/slowdns/ (from the other panel or the earlier
# verbatim install) so the keypair never changes under an upgrade.
# ---------------------------------------------------------------------
python3 - <<'PYEOF2'
import json, os
base = "/etc/vps-panel/slowdns"
p = "/etc/ragnar/settings.json"
s = json.load(open(p)) if os.path.exists(p) else {}
def readf(name):
    fp = os.path.join(base, name)
    return open(fp).read().strip() if os.path.exists(fp) else ""
if not s.get("ns") and readf("nameserver"):
    s["ns"] = readf("nameserver")
for key, fname in (("slowdns_mtu", "mtu"), ("slowdns_resolver", "dns_resolver"),
                   ("slowdns_target", "target_port")):
    if not s.get(key) and readf(fname):
        v = readf(fname)
        s[key] = v if key == "slowdns_resolver" else int(v)
json.dump(s, open(p, "w"), indent=2)
PYEOF2
ragnar_backup_file /etc/systemd/system/slowdns.service || die "Cannot preserve existing SlowDNS service"
RAGNAR_DIR="$BASE" bash "$BASE/core/slowdns-setup.sh" "${NS:-}" "" "" || \
    warn "SlowDNS setup failed - re-run: RAGNAR_DIR=$BASE bash $BASE/core/slowdns-setup.sh"

# ---------------------------------------------------------------------
# Cloudflared
# ---------------------------------------------------------------------
if ! command -v cloudflared >/dev/null; then
    if wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ZARCH}.deb \
        -O /tmp/cloudflared.deb && dpkg -i /tmp/cloudflared.deb 2>/dev/null; then
        ragnar_mark_installed cloudflared || warn "Could not record the cloudflared install for uninstall"
    else
        warn "cloudflared install failed - get it from cloudflare.com"
    fi
    rm -f /tmp/cloudflared.deb
fi

# ---------------------------------------------------------------------
# Limit checker + watchdog timers (every minute)
# ---------------------------------------------------------------------
ragnar_backup_file /etc/systemd/system/ragnar-check.service || die "Cannot preserve existing checker service"
cat > /etc/systemd/system/ragnar-check.service <<'EOF'
[Unit]
Description=Ragnar limit checker (expiry / GB quota / IP limit)
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /etc/ragnar/core/checker.py --apply
EOF
ragnar_backup_file /etc/systemd/system/ragnar-check.timer || die "Cannot preserve existing checker timer"
cat > /etc/systemd/system/ragnar-check.timer <<'EOF'
[Unit]
Description=Run Ragnar limit checker every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
ragnar_backup_file /etc/systemd/system/ragnar-watchdog.service || die "Cannot preserve existing watchdog service"
cat > /etc/systemd/system/ragnar-watchdog.service <<'EOF'
[Unit]
Description=Ragnar service watchdog
[Service]
Type=oneshot
ExecStart=/bin/bash /etc/ragnar/core/watchdog.sh
EOF
ragnar_backup_file /etc/systemd/system/ragnar-watchdog.timer || die "Cannot preserve existing watchdog timer"
cat > /etc/systemd/system/ragnar-watchdog.timer <<'EOF'
[Unit]
Description=Run Ragnar watchdog every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

# ---------------------------------------------------------------------
# Firewall (only when UFW is active - never lock the admin out)
# ---------------------------------------------------------------------
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    for p in 22/tcp 80/tcp 443/tcp 109/tcp 143/tcp 53 53/udp 53/tcp 5667/udp \
             36712/udp 6000:19999/udp 20000:65535/udp 8446/tcp 2053/tcp; do
        if ! ufw status 2>/dev/null | awk -v spec="$p" '$1 == spec {found=1} END {exit !found}'; then
            printf '%s\n' "$p" >> "$RAGNAR_STATE_DIR/ufw-added"
            ufw allow "$p" >/dev/null 2>&1 || true
        fi
    done
fi
# Same protection when UFW's chains are loaded and enforcing but
# `ufw status` does not report active (observed live 2026-11-13 on the
# hosting.de box: ufw-user-input held only fossil rules for 22/53/8080/
# 8081, so the whole panel - 80/443 included - was unreachable from
# outside and Let's Encrypt validation timed out, while the block
# above silently skipped). The UDP port ranges are NAT-redirected to
# 5667/36712 before INPUT, so those two ports cover them here.
if iptables -S ufw-user-input >/dev/null 2>&1; then
    for spec in "tcp 22" "tcp 80" "tcp 443" "tcp 109" "tcp 143" \
                "tcp 53" "udp 53" "udp 5667" "udp 36712" \
                "tcp 8446" "tcp 2053"; do
        set -- $spec
        if ! iptables -C ufw-user-input -p "$1" --dport "$2" -j ACCEPT 2>/dev/null && \
           ! iptables -C ufw-user-input -p "$1" --dport "$2" -m comment --comment "$RAGNAR_FW_COMMENT" -j ACCEPT 2>/dev/null; then
            iptables -A ufw-user-input -p "$1" --dport "$2" -m comment --comment "$RAGNAR_FW_COMMENT" -j ACCEPT 2>/dev/null || true
        fi
    done
fi
# persist iptables NAT rules across reboots
if ! netfilter-persistent save >/dev/null 2>&1; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || warn "Could not save IPv4 firewall rules"
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
fi

# ---------------------------------------------------------------------
# Generate configs + start everything
# ---------------------------------------------------------------------
RAGNAR_DIR="$BASE" python3 "$BASE/core/ragnar.py" gen-configs || true
# NOTE: do NOT copy the panel config to /usr/local/etc/xray/config.json - that path is the
# upstream installer's default, and a copy there goes stale the moment a user is added
# (the panel only regenerates /etc/ragnar/xray/config.json). The drop-in removal above
# makes Xray read the panel config directly, so no copy is needed.

# ---------------------------------------------------------------------
# Web panel (3x-ui style, HTTPS :2053 with the domain certificate)
# ---------------------------------------------------------------------
ragnar_backup_file /etc/systemd/system/ragnar-web.service || die "Cannot preserve existing web-panel service"
cat > /etc/systemd/system/ragnar-web.service <<'EOF'
[Unit]
Description=Ragnar Web Panel
After=network.target
[Service]
Type=simple
Environment=RAGNAR_DIR=/etc/ragnar
Environment=RAGNAR_WEB_BIND=127.0.0.1
Environment=RAGNAR_WEB_NO_TLS=1
Environment=RAGNAR_WEB_BASE=/panel
ExecStart=/usr/bin/python3 /etc/ragnar/web/webpanel.py
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
RAGNAR_DIR="$BASE" python3 "$BASE/web/webpanel.py" --init || true

systemctl daemon-reload
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd 2>/dev/null || true
for tmr in ragnar-check.timer ragnar-watchdog.timer; do
    systemctl enable --now "$tmr" 2>/dev/null || warn "could not start $tmr"
done
for svc in haproxy dropbear ragnar-wsproxy ragnar-landing xray sing-box zivpn \
           udp-custom badvpn-udpgw slowdns; do
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" 2>/dev/null || warn "could not start $svc (check: systemctl status $svc)"
done
if [ "$IS_UPDATE" = 1 ]; then
    python3 - "$BASE/update-status.json" "$BASE/version" <<'PY' 2>/dev/null || true
import datetime, json, os, sys
ver = ""
if os.path.exists(sys.argv[2]):
    ver = open(sys.argv[2]).read().split()[0]
data = {
    "state": "done",
    "version": ver,
    "message": f"Updated to {ver[:7] or 'latest'}.",
    "time": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
}
with open(sys.argv[1], "w") as fh:
    json.dump(data, fh, indent=1)
PY
fi
systemctl enable ragnar-web >/dev/null 2>&1 || true
systemctl restart ragnar-web 2>/dev/null || warn "could not start ragnar-web (check: systemctl status ragnar-web)"

cat <<EOF

=====================================================================
  $PANEL installed.
  Open the panel with:      menu        (or: ragnar)
  Web panel (HTTPS)   :     https://<your-domain>/panel
                            (served through HAProxy on 443, so it works
                            even where the provider firewalls port 2053;
                            login printed above by --init; reset any
                            time from menu > WEB PANEL > RESET ADMIN
                            PASSWORD)

  Ports
    22/tcp    SSH direct          109/tcp  Dropbear
    80/tcp    WS  (all protocols + SSH-WS, routed by path)
    443/tcp   WSS / SSH-SSL / AnyTLS-SNI (HAProxy front door)
    53        SlowDNS (DNSTT -> SSH)
    5667/udp  ZIVPN (+ 6000-19999/udp redirected)
    36712/udp UDP Custom (+ 20000-65535/udp redirected), badvpn-udpgw 7300
    8446/tcp  AnyTLS fallback

  Telegram : @farisbazed
  Channel  : https://t.me/ragnaresim
=====================================================================
EOF
