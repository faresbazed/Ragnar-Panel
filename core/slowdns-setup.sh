#!/usr/bin/env bash
# =====================================================================
# Ragnar SlowDNS setup - the Ragnar-VPS-Management-Panel SlowDNS,
# integrated into this panel's environment (2026-11-13).
#
#   * turbo-patched dnstt-server build:
#     turbotunnel QueueSize = 1024, smux buffers 4 MB,
#     KCP SetNoDelay(1, 10, 2, 1) + SetWindowSize(1024, 1024)
#   * their sysctl UDP buffer step, their NAT cleanup/assert block
#     (IPv4 + IPv6), their Cloudflare API auto-provisioning,
#     their systemd unit shape (Nice -15, -mtu, NAT ExecStartPre)
# Integration details:
#   * config lives in THIS panel's settings.json (keys: ns,
#     slowdns_mtu, slowdns_resolver, slowdns_target) and keys in
#     $RAGNAR_DIR/slowdns/; the other panel's files in
#     /etc/vps-panel/slowdns/ are mirrored on every run so both
#     layouts always agree (same keypair everywhere).
#   * their sshd_config rewrite step is NOT run here - this panel
#     manages its SSH config itself (both target boxes already carry
#     the same effective values from the verbatim install).
#   * MTU is a response ceiling, not a minimum required from a resolver.
#     The default of 1232 avoids fragmentation on most networks.
#
# Usage: slowdns-setup.sh [NS] [CF_TOKEN] [MTU] [RESOLVER] [TARGET]
# (same argument order as the other panel's ragnar-slowdns-setup;
# empty arguments keep the values stored in settings.json)
# =====================================================================
set -uo pipefail

BASE="${RAGNAR_DIR:-/etc/ragnar}"
SD_DIR="$BASE/slowdns"
THEIR_DIR="/etc/vps-panel/slowdns"
SETTINGS="$BASE/settings.json"
BIN=/usr/local/bin/dnstt-server
MARKER="$SD_DIR/.turbo_kcp_patched"
BUILD_STAMP="$SD_DIR/.dnstt-build"
SERVER_PATCH="$BASE/core/dnstt-server.patch"
DNSTT_RELEASE=20260501
DNSTT_SHA256=a7b21d3d787570d9127643e360e150d2da7b33aa8039d0546a04dcfe8ee1864f
BUILD_LOG=/tmp/ragnar-slowdns-build.log
mkdir -p "$SD_DIR" "$THEIR_DIR"

# The SlowDNS binary and unit may also be used by the sister panel. Snapshot
# them once so uninstall can restore the pre-Ragnar version rather than
# deleting shared components.
if [ -r "$BASE/core/install-state.sh" ]; then
    . "$BASE/core/install-state.sh"
    ragnar_state_init || { echo "[slowdns-setup] cannot create installer state directory" >&2; exit 1; }
    ragnar_backup_file "$BIN" || { echo "[slowdns-setup] cannot preserve existing dnstt-server" >&2; exit 1; }
    ragnar_backup_file /etc/systemd/system/slowdns.service || {
        echo "[slowdns-setup] cannot preserve existing SlowDNS service" >&2; exit 1;
    }
    for file in server.key server.pub .turbo_kcp_patched nameserver mtu dns_resolver target_port; do
        ragnar_backup_file "$THEIR_DIR/$file" || {
            echo "[slowdns-setup] cannot preserve shared SlowDNS file: $file" >&2; exit 1;
        }
    done
fi

say() { echo "[slowdns-setup] $*"; }

get_setting() { # key default
    python3 - "$SETTINGS" "$1" "$2" <<'PY'
import json, os, sys
p, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
s = json.load(open(p)) if os.path.exists(p) else {}
v = s.get(key)
print(default if v is None or v == "" else v)
PY
}

store_settings() { # ns mtu resolver target - empty keeps the old value
    python3 - "$SETTINGS" "$1" "$2" "$3" "$4" <<'PY'
import json, os, re, sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) else {}
keys = ("ns", "slowdns_mtu", "slowdns_resolver", "slowdns_target")
for key, val in zip(keys, sys.argv[2:]):
    if val:
        s[key] = val
ns = s.get("ns") or ""
if ns and (not isinstance(ns, str) or len(ns.rstrip(".")) > 253
           or any(not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                  for label in ns.removesuffix(".").split("."))):
    sys.exit("[slowdns-setup] Invalid SlowDNS nameserver")
for key, low, high in (("slowdns_mtu", 512, 4096), ("slowdns_target", 1, 65535)):
    val = s.get(key)
    if val is not None and val != "":
        if not re.fullmatch(r"[0-9]{1,5}", str(val)) or not low <= int(val) <= high:
            sys.exit(f"[slowdns-setup] {key} must be between {low} and {high}")
        s[key] = int(val)
json.dump(s, open(p, "w"), indent=2)
PY
}

# Adopt the other panel's keypair if it exists and ours does not
# (keeps the live SlowDNS identity across the integration).
for f in server.key server.pub; do
    if [ ! -s "$SD_DIR/$f" ] && [ -s "$THEIR_DIR/$f" ]; then
        cp "$THEIR_DIR/$f" "$SD_DIR/$f"
    fi
done

CF_TOKEN="${2:-}"
store_settings "${1:-}" "${3:-}" "${4:-}" "${5:-}" || exit 1
NS=$(get_setting ns "")
MTU=$(get_setting slowdns_mtu 1232)
RESOLVER=$(get_setting slowdns_resolver 1.1.1.1)
TARGET=$(get_setting slowdns_target 22)

# ---------------------------------------------------------------------
# 1. Kernel UDP buffers (their step 1; the maximums are only ever
#    raised here, never lowered - this panel's sysctl file sets 64 MB)
# ---------------------------------------------------------------------
sysctl -w net.core.rmem_default=16777216 >/dev/null 2>&1 || true
sysctl -w net.core.wmem_default=16777216 >/dev/null 2>&1 || true
for k in net.core.rmem_max net.core.wmem_max; do
    cur=$(sysctl -n "$k" 2>/dev/null || echo 0)
    if [ "${cur:-0}" -lt 33554432 ]; then
        sysctl -w "$k=33554432" >/dev/null 2>&1 || true
    fi
done
sysctl -w net.core.netdev_max_backlog=16384 >/dev/null 2>&1 || true

# ---------------------------------------------------------------------
# Go toolchain (dnstt needs Go >= 1.21)
# ---------------------------------------------------------------------
go_is_new_enough() {
    [ -n "$1" ] || return 1
    local maj min
    maj=$("$1" version 2>/dev/null | sed -E 's/.*go([0-9]+)\.([0-9]+).*/\1/')
    min=$("$1" version 2>/dev/null | sed -E 's/.*go([0-9]+)\.([0-9]+).*/\2/')
    [ "${maj:-0}" -gt 1 ] || { [ "${maj:-0}" -eq 1 ] && [ "${min:-0}" -ge 21 ]; }
}

ensure_go() {
    : >>"$BUILD_LOG"
    local go_bin ga temp
    go_bin=$(command -v go || true)
    if ! go_is_new_enough "$go_bin" && [ -x /usr/local/go/bin/go ]; then
        go_bin=/usr/local/go/bin/go
    fi
    if ! go_is_new_enough "$go_bin" && [ -x /usr/local/go-1.22/bin/go ]; then
        go_bin=/usr/local/go-1.22/bin/go
    fi
    if ! go_is_new_enough "$go_bin"; then
        apt-get install -y -q golang-go >>"$BUILD_LOG" 2>&1 || true
        go_bin=$(command -v go || true)
    fi
    if ! go_is_new_enough "$go_bin"; then
        case "$(uname -m)" in aarch64|arm64) ga=arm64 ;; *) ga=amd64 ;; esac
        temp=$(mktemp -d /usr/local/.ragnar-go.XXXXXX) || return 1
        if wget -q "https://go.dev/dl/go1.22.12.linux-${ga}.tar.gz" \
                -O "$temp/go.tgz" >>"$BUILD_LOG" 2>&1 && \
           tar -C "$temp" -xzf "$temp/go.tgz" >>"$BUILD_LOG" 2>&1 && \
           rm -rf /usr/local/go-1.22 && mv "$temp/go" /usr/local/go-1.22; then
            go_bin=/usr/local/go-1.22/bin/go
        fi
        rm -rf "$temp"
    fi
    go_is_new_enough "$go_bin" && { echo "$go_bin"; return 0; }
    return 1
}

# ---------------------------------------------------------------------
# 2. Build the patched dnstt-server against a pinned upstream release.
#    Replace the live binary only after the complete build succeeds.
# ---------------------------------------------------------------------
build_server() (
    local tmp staged
    tmp=$(mktemp -d -p /var/tmp) || return 1
    staged=$(mktemp "${BIN}.XXXXXX") || { rm -rf "$tmp"; return 1; }
    trap 'rm -rf "$tmp"; rm -f "$staged"' EXIT
    curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
        "https://www.bamsoftware.com/software/dnstt/dnstt-${DNSTT_RELEASE}.zip" -o "$tmp/source.zip" &&
        printf '%s  %s\n' "$DNSTT_SHA256" "$tmp/source.zip" | sha256sum --check --status &&
        unzip -q "$tmp/source.zip" -d "$tmp" &&
        cd "$tmp/dnstt-$DNSTT_RELEASE" &&
        patch --batch --forward --fuzz=0 -p1 < "$SERVER_PATCH" &&
        GOPROXY=https://proxy.golang.org,direct CGO_ENABLED=0 \
            "$GO_BIN" build -ldflags="-s -w" -trimpath -o "$staged" ./dnstt-server &&
        chmod 755 "$staged" && mv -f "$staged" "$BIN"
)

BUILD_ID=$(sha256sum < "$SERVER_PATCH") || { say "ERROR: cannot read $SERVER_PATCH"; exit 1; }
BUILD_ID="$DNSTT_RELEASE $BUILD_ID"
if [ "${SLOWDNS_REBUILD:-0}" = 1 ] || [ ! -x "$BIN" ] || [ ! -f "$MARKER" ] || \
   [ "$(cat "$BUILD_STAMP" 2>/dev/null)" != "$BUILD_ID" ]; then
    say "Building Turbo dnstt-server with adaptive resolver limits..."
    GO_BIN=$(ensure_go) || { say "ERROR: no Go >= 1.21 toolchain available - see $BUILD_LOG"; exit 1; }
    if build_server >>"$BUILD_LOG" 2>&1; then
        printf '%s\n' "$BUILD_ID" > "$BUILD_STAMP" && touch "$MARKER" || exit 1
        say "Built $BIN"
    else
        say "ERROR: dnstt-server build failed - see $BUILD_LOG"
        exit 1
    fi
fi

# ---------------------------------------------------------------------
# 3. Keypair (generate once, preserve forever) + mirror their layout
# ---------------------------------------------------------------------
if [ ! -s "$SD_DIR/server.key" ] || [ ! -s "$SD_DIR/server.pub" ]; then
    "$BIN" -gen-key -privkey-file "$SD_DIR/server.key" \
        -pubkey-file "$SD_DIR/server.pub" || {
        say "ERROR: key generation failed"; exit 1; }
    chmod 600 "$SD_DIR/server.key"
fi
cp "$SD_DIR/server.key" "$SD_DIR/server.pub" "$THEIR_DIR/" 2>/dev/null || true
chmod 600 "$THEIR_DIR/server.key" 2>/dev/null || true
[ -f "$MARKER" ] && touch "$THEIR_DIR/.turbo_kcp_patched" || true
printf '%s\n' "$NS" > "$THEIR_DIR/nameserver"
printf '%s\n' "$MTU" > "$THEIR_DIR/mtu"
printf '%s\n' "$RESOLVER" > "$THEIR_DIR/dns_resolver"
printf '%s\n' "$TARGET" > "$THEIR_DIR/target_port"
python3 - "$SETTINGS" "$SD_DIR/server.pub" <<'PY'
import json, os, sys
p = sys.argv[1]
s = json.load(open(p)) if os.path.exists(p) else {}
s["slowdns_pubkey"] = open(sys.argv[2]).read().strip()
s.pop("slowdns_kcp", None)
json.dump(s, open(p, "w"), indent=2)
PY

# ---------------------------------------------------------------------
# 4. Optional Cloudflare DNS provisioning (A record + NS delegation)
# ---------------------------------------------------------------------
cloudflare() {
    curl -fsSL --max-time 10 -H "Authorization: Bearer $CF_TOKEN" \
        "https://api.cloudflare.com/client/v4/$1" "${@:2}"
}

set_dns_record() {
    local type="$1" name="$2" content="$3" endpoint="zones/$ZONE_ID/dns_records"
    local record_id data method=POST
    record_id=$(cloudflare "$endpoint?type=$type&name=$name" | jq -er '
        select(.success == true) | (.result[0].id // "")') || return 1
    if [ -n "$record_id" ]; then
        method=PATCH
        endpoint="$endpoint/$record_id"
    fi
    data=$(jq -cn --arg type "$type" --arg name "$name" --arg content "$content" '
        {type: $type, name: $name, content: $content, ttl: 1} +
        (if $type == "A" then {proxied: false} else {} end)') || return 1
    cloudflare "$endpoint" -X "$method" -H "Content-Type: application/json" --data "$data" |
        jq -e '.success == true' >/dev/null
}

ACTIVE_NS="$NS"
if [ -n "$CF_TOKEN" ] && [ -n "$ACTIVE_NS" ]; then
    VPS_IP=$(curl -fsSL4 --max-time 3 https://icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
    ACTIVE_NS="${ACTIVE_NS%.}"
    ROOT_DOM="${ACTIVE_NS#*.}"
    ZONE_ID=""
    while [[ "$ROOT_DOM" == *.* && "$ROOT_DOM" != "$ACTIVE_NS" ]]; do
        ZONE_ID=$(cloudflare "zones?name=$ROOT_DOM" | jq -r '.result[0].id // empty' || true)
        [ -n "$ZONE_ID" ] && break
        ROOT_DOM="${ROOT_DOM#*.}"
    done
    A_HOST="dns.${ROOT_DOM}"
    if [ -n "${ZONE_ID}" ]; then
        [ "${ACTIVE_NS,,}" != "${A_HOST,,}" ] || A_HOST="dns-server.${ROOT_DOM}"
        if set_dns_record A "$A_HOST" "$VPS_IP" && set_dns_record NS "$ACTIVE_NS" "$A_HOST"; then
            echo "Cloudflare DNS configured: ${ACTIVE_NS} -> ${A_HOST} (${VPS_IP})"
        else
            echo "Warning: Cloudflare DNS setup failed; check or create the A and NS records manually."
        fi
    else
        echo "Warning: No parent Cloudflare zone found for ${ACTIVE_NS}. Verify the token has Zone:Read and DNS:Edit."
    fi
fi

if [ -z "$NS" ]; then
    say "Binary and keys are ready, but no nameserver is set."
    say "Set it in the panel menu (SLOWDNS) to start the service."
    exit 0
fi

# ---------------------------------------------------------------------
# 5. UDP 53 -> 5300 redirection. Keep existing equivalent rules (they
#    may belong to the sister panel); add tagged rules only when missing.
# ---------------------------------------------------------------------
FW_COMMENT=ragnar-slowdns
MAIN_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
for fw in iptables ip6tables; do
    command -v "$fw" >/dev/null 2>&1 || continue
    for ports in '5300 53' '53 5300'; do
        read -r from to <<< "$ports"
        while "$fw" -t nat -D PREROUTING -p udp --dport "$from" -j REDIRECT --to-ports "$to" 2>/dev/null; do :; done
        if [ -n "$MAIN_IFACE" ]; then
            while "$fw" -t nat -D PREROUTING -i "$MAIN_IFACE" -p udp --dport "$from" -j REDIRECT --to-ports "$to" 2>/dev/null; do :; done
        fi
    done
done
for port in 53 5300; do
    if ! iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null && \
       ! iptables -C INPUT -p udp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p udp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null || true
    fi
done
if ! iptables -t nat -C PREROUTING ! -d 127.0.0.0/8 -p udp --dport 53 \
        -j REDIRECT --to-ports 5300 2>/dev/null && \
   ! iptables -t nat -C PREROUTING ! -d 127.0.0.0/8 -p udp --dport 53 \
        -m comment --comment "$FW_COMMENT" -j REDIRECT --to-ports 5300 2>/dev/null; then
    iptables -t nat -I PREROUTING ! -d 127.0.0.0/8 -p udp --dport 53 \
        -m comment --comment "$FW_COMMENT" -j REDIRECT --to-ports 5300 2>/dev/null || true
fi

if command -v ip6tables >/dev/null 2>&1; then
    for port in 53 5300; do
        if ! ip6tables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null && \
           ! ip6tables -C INPUT -p udp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null; then
            ip6tables -I INPUT -p udp --dport "$port" -m comment --comment "$FW_COMMENT" -j ACCEPT 2>/dev/null || true
        fi
    done
    if ! ip6tables -t nat -C PREROUTING ! -d ::1/128 -p udp --dport 53 \
            -j REDIRECT --to-ports 5300 2>/dev/null && \
       ! ip6tables -t nat -C PREROUTING ! -d ::1/128 -p udp --dport 53 \
            -m comment --comment "$FW_COMMENT" -j REDIRECT --to-ports 5300 2>/dev/null; then
        ip6tables -t nat -I PREROUTING ! -d ::1/128 -p udp --dport 53 \
            -m comment --comment "$FW_COMMENT" -j REDIRECT --to-ports 5300 2>/dev/null || true
    fi
fi

if command -v ufw >/dev/null 2>&1; then
    for port in 53/udp 5300/udp; do
        if ! ufw status 2>/dev/null | awk -v spec="$port" '$1 == spec {found=1} END {exit !found}'; then
            [ -n "${RAGNAR_STATE_DIR:-}" ] && printf '%s\n' "$port" >> "$RAGNAR_STATE_DIR/ufw-added"
            ufw allow "$port" >/dev/null 2>&1 || true
        fi
    done
fi

# Stop MasterDnsVPN if it was previously occupying UDP port 53 (theirs)
systemctl stop masterdnsvpn 2>/dev/null || true
systemctl disable masterdnsvpn 2>/dev/null || true

# ---------------------------------------------------------------------
# 6. systemd unit (their shape, this panel's key path)
# ---------------------------------------------------------------------
# The unit must call iptables by absolute path, but that path differs by
# distro: /sbin/iptables on Ubuntu, /usr/sbin/iptables on Debian (where
# /sbin/iptables simply does not exist and systemd silently skips the
# ExecStartPre lines). Resolve it here instead of hardcoding one distro.
IPTABLES_BIN=$(command -v iptables || echo /usr/sbin/iptables)
IP6TABLES_BIN=$(command -v ip6tables || true)
firewall_prestart() {
    local fw loopback port rule
    for fw in "$IPTABLES_BIN" "$IP6TABLES_BIN"; do
        [ -n "$fw" ] || continue
        loopback=127.0.0.0/8
        [ "$fw" = "$IP6TABLES_BIN" ] && loopback=::1/128
        # Escape systemd specifiers and environment expansion in executable paths.
        fw=${fw//%/%%}
        fw=${fw//\$/\$\$}
        for port in 53 5300 redirect; do
            if [ "$port" = redirect ]; then
                rule="-t nat %s PREROUTING ! -d $loopback -p udp --dport 53 %s -j REDIRECT --to-ports 5300"
            else
                rule="%s INPUT -p udp --dport $port %s -j ACCEPT"
            fi
            printf 'ExecStartPre=-/bin/sh -c "\x27%s\x27 %s || \x27%s\x27 %s || \x27%s\x27 %s"\n' \
                "$fw" "$(printf -- "$rule" -C '')" \
                "$fw" "$(printf -- "$rule" -C '-m comment --comment ragnar-slowdns')" \
                "$fw" "$(printf -- "$rule" -I '-m comment --comment ragnar-slowdns')"
        done
    done
}
cat > /etc/systemd/system/slowdns.service <<EOF
[Unit]
Description=Ragnar Turbo SlowDNS (DNSTT) Server (UDP 53 -> 5300 -> 127.0.0.1:${TARGET}, MTU ${MTU})
After=network.target ssh.service dropbear.service

[Service]
Type=simple
Nice=-15
LimitNOFILE=1000000
$(firewall_prestart)
ExecStart=$BIN -udp :5300 -mtu ${MTU} -privkey-file $SD_DIR/server.key ${NS} 127.0.0.1:${TARGET}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

if ! systemctl daemon-reload || ! systemctl enable slowdns >/dev/null || ! systemctl restart slowdns; then
    say "ERROR: could not start SlowDNS - check systemctl status slowdns"
    exit 1
fi
say "SlowDNS started: NS ${NS}, MTU ceiling ${MTU}, suggested client resolver ${RESOLVER}, target 127.0.0.1:${TARGET}"
