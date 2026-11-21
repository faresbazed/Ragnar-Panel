#!/bin/bash
# =====================================================================
# Ragnar VPS Management Panel - main menu
# Telegram : @farisbazed
# Channel  : https://t.me/ragnaresim
# =====================================================================
RAGNAR_DIR="${RAGNAR_DIR:-/etc/ragnar}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="${RAGNAR_CORE:-$RAGNAR_DIR/core/ragnar.py}"
[ -f "$CORE" ] || CORE="$DIR/core/ragnar.py"
export RAGNAR_DIR

# ---- terminal UI -----------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    P='\033[95m'; P2='\033[35m'; C='\033[96m'; G='\033[92m'; Y='\033[93m'
    W='\033[97m'; R='\033[91m'; DIM='\033[90m'; N='\033[0m'; B='\033[1m'
else
    P=''; P2=''; C=''; G=''; Y=''; W=''; R=''; DIM=''; N=''; B=''
fi

term_width() {
    local width
    width=$(tput cols 2>/dev/null || printf '80')
    [[ "$width" =~ ^[0-9]+$ ]] || width=80
    (( width < 44 )) && width=44
    (( width > 96 )) && width=96
    printf '%s\n' "$width"
}
clear_screen() { [ -t 1 ] && clear 2>/dev/null || true; }
bar() {
    local title="$1" width inner left right line max
    width=$(term_width); inner=$((width - 2)); max=$((inner - 4))
    [ "${#title}" -le "$max" ] || title="${title:0:max}"
    left=$(( (inner - ${#title}) / 2 )); right=$((inner - ${#title} - left))
    line=$(printf '%*s' "$inner" '')
    line=${line// /─}
    printf "${P}┌%s┐${N}\n" "$line"
    printf "${P}│${N}%*s${Y}${B}%s${N}%*s${P}│${N}\n" "$left" '' "$title" "$right" ''
    printf "${P}└%s┘${N}\n" "$line"
}
kv() { printf "  ${C}%-14s${W}: ${G}%s${N}\n" "$1" "$2"; }
opt() {
    local key="$1" label="$2" detail="${3:-}" width detail_width
    width=$(term_width); detail_width=$((width - 40))
    (( detail_width < 3 )) && detail_width=3
    if [ "${#detail}" -gt "$detail_width" ]; then
        detail="${detail:0:$((detail_width - 3))}..."
    fi
    printf "  ${P}%-4s${W} %-30s${DIM}%s${N}\n" "[$key]" "$label" "$detail"
}
section() { printf "\n${P2}${B}  %s${N}\n" "$1"; }
page_header() {
    local title="$1" detail="${2:-}" host
    clear_screen
    host=$(cat "$RAGNAR_DIR/host" 2>/dev/null)
    [ -n "$host" ] || host=$(server_ip)
    printf "${P2}${B}RAGNAR VPS PANEL${N}\n"
    printf "${DIM}HOST %s  ·  0 / B = back${N}\n" "${host:-n/a}"
    bar "$title"
    [ -z "$detail" ] || printf "  ${W}%s${N}\n" "$detail"
}
menu_choice() {
    local prompt="${1:-Select an option}"
    read -rp "$prompt " MENU_CHOICE || return 1
    case "$MENU_CHOICE" in b|B|back|BACK|q|Q) MENU_CHOICE=0 ;; esac
}
invalid_choice() { echo -e "${R}  Invalid option. Choose a listed number, or 0 to go back.${N}"; pause; }
svc_dot() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "${G}● ONLINE${N}"
    else
        echo -e "${R}● OFFLINE${N}"
    fi
}
svc_dot_cf() { # cloudflared only runs once a tunnel token is installed
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        echo -e "${G}● ONLINE${N}"
    elif systemctl list-unit-files cloudflared.service >/dev/null 2>&1 \
         && systemctl list-unit-files cloudflared.service | grep -q cloudflared; then
        echo -e "${R}● OFFLINE${N}"
    else
        echo -e "${Y}● NO TUNNEL${N}"
    fi
}
pause() { read -rp "Press Enter to continue..." _ || true; }

bandwidth_lines() { # Combined RX+TX total for today and this month
    python3 "$CORE" bandwidth-summary 2>/dev/null \
        | while IFS= read -r l; do echo -e "${C}$l${N}"; done
}

human() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 B"; }
stats_count() {
    python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], 0))' "$1" <<<"$2" 2>/dev/null || echo 0
}

server_ip() {
    local f="$RAGNAR_DIR/host" ip
    [ -s "$f" ] && cat "$f" && return
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -n "$ip" ] || ip=$(curl -s4 --max-time 2 https://api.ipify.org 2>/dev/null || echo "n/a")
    printf '%s\n' "$ip"
}
server_isp() {
    local f="$RAGNAR_DIR/isp" isp
    if [ -s "$f" ]; then
        cat "$f"
        return
    fi
    isp=$(curl -s --max-time 2 "https://ipinfo.io/org" 2>/dev/null | sed 's/^AS[0-9]* //' | head -1)
    if [ -n "$isp" ]; then
        mkdir -p "$RAGNAR_DIR" 2>/dev/null && printf '%s\n' "$isp" > "$f" 2>/dev/null || true
        printf '%s\n' "$isp"
    else
        echo "Unknown"
    fi
}
cpu_usage_pct() {
    if [ -r /proc/stat ]; then
        local u1 n1 s1 i1 w1 q1 sq1 st1 u2 n2 s2 i2 w2 q2 sq2 st2 _
        read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
        read -t 0.04 _ < <(sleep 0.04) 2>/dev/null || sleep 0.04
        read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
        awk -v t1="$((u1+n1+s1+i1+w1+q1+sq1+st1))" -v id1="$((i1+w1))" \
            -v t2="$((u2+n2+s2+i2+w2+q2+sq2+st2))" -v id2="$((i2+w2))" \
            'BEGIN { dt=t2-t1; if (dt>0) printf "%.1f%%", (dt-(id2-id1))*100/dt; else print "0.0%" }'
    else
        echo "n/a"
    fi
}

print_header() {
    clear_screen
    local ip isp os up cpu ram disk now
    ip=$(server_ip); isp=$(server_isp)
    os=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    up=$(uptime -p 2>/dev/null | sed 's/^up //')
    cpu=$(cpu_usage_pct)
    ram=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t>0) printf "%dMB / %dMB (%.0f%%)", (t-a)/1024, t/1024, (t-a)*100/t}' /proc/meminfo 2>/dev/null)
    disk=$(df -Ph / 2>/dev/null | awk 'NR==2 {if ($2 == "0" || $2 == "0B") printf "%s used", $3; else printf "%s / %s (%s)", $3, $2, $5}')
    now=$(date '+%d-%m-%Y %T')

    # Single Python call for bandwidth + user stats + online count
    local dash_tsv bw_today bw_month bw_src s_vmess s_vless s_trojan s_ssws s_ssh s_zivpn s_total s_online
    dash_tsv=$(python3 - "$CORE" <<'PY' 2>/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ragnar", sys.argv[1])
r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
d = r.dashboard_summary()
bw, st, on = d["bandwidth"], d["stats"], d["online"]
t = (bw.get("today") or {}).get("total_f", "n/a")
m = (bw.get("month") or {}).get("total_f", "n/a")
src = bw.get("source") or ""
print("\t".join(str(x) for x in [
    t, m, src if src != "vnstat" else "",
    st.get("vmess", 0), st.get("vless", 0), st.get("trojan", 0),
    st.get("ssws", 0), st.get("ssh", 0), st.get("zivpn", 0),
    st.get("total", 0), on.get("online", 0)
]))
PY
)
    IFS=$'\t' read -r bw_today bw_month bw_src s_vmess s_vless s_trojan s_ssws s_ssh s_zivpn s_total s_online <<<"$dash_tsv"

    # Single batched systemctl call for all header services
    local -a units=(xray haproxy dropbear sing-box udp-custom zivpn ragnar-wsproxy slowdns badvpn-udpgw ragnar-web cloudflared)
    local -a states=()
    mapfile -t states < <(systemctl is-active "${units[@]}" 2>/dev/null || true)
    declare -A svc_map=()
    local idx key
    for idx in "${!units[@]}"; do
        key="${units[$idx]}"
        if [ "${states[$idx]:-inactive}" = "active" ]; then
            svc_map["$key"]="${G}$(printf '%-15s' '● ONLINE')${N}"
        else
            svc_map["$key"]="${R}$(printf '%-15s' '● OFFLINE')${N}"
        fi
    done
    if [ "${states[10]:-inactive}" != "active" ] \
       && [ ! -f /etc/systemd/system/cloudflared.service ] \
       && [ ! -f /lib/systemd/system/cloudflared.service ]; then
        svc_map["cloudflared"]="${Y}$(printf '%-15s' '● NO TUNNEL')${N}"
    fi

    echo -e "${P2}${B}  RAGNAR VPS PANEL${N}"
    echo -e "${C}  Telegram : ${W}@farisbazed${C}   Channel : ${W}https://t.me/ragnaresim${N}"
    bar "SERVER INFO"
    kv "IP" "${ip:-n/a}";     kv "ISP" "${isp:-Unknown}"; kv "OS" "${os:-Linux}"
    kv "UPTIME" "${up:-n/a}"; kv "CPU USAGE" "${cpu:-n/a}"
    kv "RAM USAGE" "${ram:-n/a}"; kv "DISK USAGE" "${disk:-n/a}"; kv "SERVER TIME" "$now"

    bar "BANDWIDTH"
    printf "  ${C}%-14s${W}: ${G}%-16s${C}%-14s${W}: ${G}%s${N}\n" \
        "TODAY" "${bw_today:-n/a}" "MONTH" "${bw_month:-n/a}"
    [ -z "${bw_src:-}" ] || printf "  ${DIM}(bandwidth source: %s)${N}\n" "$bw_src"

    bar "USER STATS"
    printf "  ${C}%-8s${W}: ${G}%-6s${C}%-8s${W}: ${G}%-6s${C}%-8s${W}: ${G}%s${N}\n" \
        "VMESS" "${s_vmess:-0}" "VLESS" "${s_vless:-0}" "TROJAN" "${s_trojan:-0}"
    printf "  ${C}%-8s${W}: ${G}%-6s${C}%-8s${W}: ${G}%-6s${C}%-8s${W}: ${G}%s${N}\n" \
        "SSWS" "${s_ssws:-0}" "SSH" "${s_ssh:-0}" "ZIVPN" "${s_zivpn:-0}"
    printf "  ${C}%-8s${W}: ${G}%-6s${C}%-8s${W}: ${G}%s${N}\n" \
        "TOTAL" "${s_total:-0}" "ONLINE" "${s_online:-0}"

    bar "SERVICE"
    printf "  ${C}%-12s${W}: %b${C}%-12s${W}: %b\n" "XRAY" "${svc_map[xray]}" "HAPROXY" "${svc_map[haproxy]}"
    printf "  ${C}%-12s${W}: %b${C}%-12s${W}: %b\n" "DROPBEAR" "${svc_map[dropbear]}" "SING-BOX" "${svc_map[sing-box]}"
    printf "  ${C}%-12s${W}: %b${C}%-12s${W}: %b\n" "UDP CUSTOM" "${svc_map[udp-custom]}" "UDP ZIVPN" "${svc_map[zivpn]}"
    printf "  ${C}%-12s${W}: %b${C}%-12s${W}: %b\n" "SSH WS" "${svc_map[ragnar-wsproxy]}" "WSS / SSL" "${svc_map[haproxy]}"
    printf "  ${C}%-12s${W}: %b${C}%-12s${W}: %b\n" "SLOWDNS" "${svc_map[slowdns]}" "BADVPN" "${svc_map[badvpn-udpgw]}"
    printf "  ${C}%-12s${W}: %b${C}%-12s${W}: %b\n" "CLOUDFLARED" "${svc_map[cloudflared]}" "WEB PANEL" "${svc_map[ragnar-web]}"
}

main_menu() {
    bar "NAVIGATION"
    section "ACCOUNTS & ACCESS"
    opt 1 "SSH / SSL accounts" "Users, expiry, quota, IP limits"
    opt 2 "Xray accounts" "VLESS · VMess · Trojan · SSWS · AnyTLS"
    opt 3 "UDP ZIVPN" "Passwords and UDP access"
    opt 4 "UDP Custom" "SSH-backed UDP gateway"
    section "SERVICES & MONITORING"
    opt 5 "SlowDNS" "Nameserver, resolver, keys and MTU"
    opt 6 "Cloudflare" "Domains, links and tunnel"
    opt 7 "Web panel" "URL, admin password and service"
    opt 8 "Status" "Services, bandwidth and listening ports"
    opt 9 "Tools" "Restart, backup, checks and diagnostics"
    section "SYSTEM"
    opt 10 "Update panel" "Back up state, then update from GitHub"
    opt 11 "Clear RAM cache" "Drop Linux filesystem caches"
    opt 12 "Reboot VPS" "Restart the whole server"
    opt 13 "Uninstall panel" "Restore snapshots and remove Ragnar"
    opt x "Exit" "Leave this menu"
    printf "\n${DIM}  Panel by @farisbazed · https://t.me/ragnaresim${N}\n"
}

# ---------------------------------------------------------------------
# SSH submenu
# ---------------------------------------------------------------------
ssh_create() {
    local u p d q i
    read -rp "Username        : " u
    read -rsp "Password        : " p; echo
    read -rp "Duration (days) : " d
    read -rp "Quota GB (0=inf): " q
    read -rp "IP limit (0=inf): " i
    python3 "$CORE" ssh-add "$u" "$p" "${d:-30}" "${q:-0}" "${i:-0}"
    pause
}
ssh_list() { python3 "$CORE" ssh-list; pause; }
ssh_info() { local u; read -rp "Username: " u; python3 "$CORE" ssh-info "$u"; pause; }
ssh_edit() {
    local u what v
    read -rp "Username to edit: " u
    page_header "EDIT SSH ACCOUNT" "Choose one account setting to update."
    echo "  Account: ${u:-<not set>}"
    section "ACCOUNT SETTINGS"
    opt 1 "Renew / extend expiry" "Add days to the current expiry"
    opt 2 "Set traffic quota" "Enter GB; 0 means unlimited"
    opt 3 "Set IP limit" "Enter simultaneous IPs; 0 means unlimited"
    opt 4 "Change password" "Password input is hidden"
    opt 5 "Enable account" "Allow this user to log in"
    opt 6 "Disable account" "Block this user from logging in"
    opt 0 "Cancel" "Return without changes"
    menu_choice "Select an option:" || return
    what=$MENU_CHOICE
    case $what in
        1) read -rp "Add how many days? " v; python3 "$CORE" ssh-edit "$u" --days "$v" --extend ;;
        2) read -rp "New quota GB (0=inf): " v; python3 "$CORE" ssh-edit "$u" --quota-gb "$v" ;;
        3) read -rp "New IP limit (0=inf): " v; python3 "$CORE" ssh-edit "$u" --ip-limit "$v" ;;
        4) read -rsp "New password: " v; echo; python3 "$CORE" ssh-edit "$u" --password "$v" ;;
        5) python3 "$CORE" ssh-edit "$u" --enable ;;
        6) python3 "$CORE" ssh-edit "$u" --disable ;;
        0) return ;;
        *) invalid_choice; return ;;
    esac
    pause
}
ssh_del() {
    local u a
    page_header "DELETE SSH ACCOUNT" "Deletion removes the account from the panel and its host access."
    read -rp "Username to delete: " u
    read -rp "Delete '${u:-<not set>}'? [y/N] " a
    case "$a" in y|Y) python3 "$CORE" ssh-del "$u" ;; *) echo "No changes made." ;; esac
    pause
}
ssh_menu() {
    while true; do
        page_header "SSH & SSL" "Manage shell accounts, access limits and connection services."
        printf "  OpenSSH : %s   Dropbear : %s   SSH-WS : %s\n" \
            "$(svc_dot ssh)" "$(svc_dot dropbear)" "$(svc_dot ragnar-wsproxy)"
        section "ACCOUNT MANAGEMENT"
        opt 1 "Create account" "Username, password, expiry and limits"
        opt 2 "List accounts" "Show users, traffic used and quota"
        opt 3 "Edit / renew account" "Expiry, quota, IP limit, password or access"
        opt 4 "Delete account" "Remove a panel user"
        opt 5 "Account details" "Ports, expiry, quota and live connections"
        section "CONNECTIONS & SERVICES"
        opt 6 "Connection details" "OpenSSH :22 · Dropbear :109 · SSH-WS :443"
        opt 7 "Service status" "Inspect SSH, Dropbear and WebSocket proxy"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) ssh_create ;; 2) ssh_list ;; 3) ssh_edit ;;
            4) ssh_del ;; 5) ssh_info ;;
            6) echo "OpenSSH    : $(server_ip):22/tcp"; echo "Dropbear   : $(server_ip):109/tcp";
               echo "SSH-WS/SSL : $(server_ip):443/tcp (via HAProxy)"; pause ;;
            7) systemctl --no-pager status ssh dropbear ragnar-wsproxy 2>&1 | sed -n '1,42p'; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}

# ---------------------------------------------------------------------
# Xray submenu (one user -> VLESS+VMESS+Trojan+SSWS+AnyTLS together)
# ---------------------------------------------------------------------
xray_create() {
    local u d q i custom_uuid
    read -rp "Username        : " u
    read -rp "Duration (days) : " d
    read -rp "Quota GB (0=inf): " q
    read -rp "IP limit (0=inf): " i
    read -rp "Custom UUID for VLESS/VMess (blank = generate): " custom_uuid
    local -a args=("$u" "${d:-30}" "${q:-0}" "${i:-0}")
    [ -n "$custom_uuid" ] && args+=("$custom_uuid")
    if python3 "$CORE" xray-add "${args[@]}"; then
        echo -e "${G}All protocols created together. Links above include direct 80/443 and Cloudflare 80/443.${N}"
    fi
    pause
}
xray_links() {
    local u; read -rp "Username: " u
    python3 "$CORE" xray-links "$u"
    pause
}
xray_info() { local u; read -rp "Username: " u; python3 "$CORE" xray-info "$u"; pause; }
xray_copy_one() {
    local u proto
    read -rp "Username: " u
    page_header "SELECT XRAY LINK" "Choose one protocol link to copy or share."
    opt 1 "VLESS" ""
    opt 2 "VMess" ""
    opt 3 "Trojan" ""
    opt 4 "Shadowsocks WS" ""
    opt 5 "AnyTLS" ""
    opt 0 "Cancel" "Return without displaying links"
    menu_choice "Protocol:" || return
    case "$MENU_CHOICE" in
        1) proto=VLESS ;; 2) proto=VMESS ;; 3) proto=TROJAN ;;
        4) proto=SSWS ;; 5) proto=ANYTLS ;; 0) return ;;
        *) invalid_choice; return ;;
    esac
    python3 "$CORE" xray-links "$u" | grep -i "^$proto" || echo "No $proto link found for '${u}'."
    pause
}
xray_edit() {
    local u what v
    read -rp "Username to edit: " u
    page_header "EDIT XRAY ACCOUNT" "Changes apply to this user across the enabled Xray protocols."
    echo "  Account: ${u:-<not set>}"
    section "ACCOUNT SETTINGS"
    opt 1 "Renew / extend expiry" "Add days to the current expiry"
    opt 2 "Set traffic quota" "Enter GB; 0 means unlimited"
    opt 3 "Set IP limit" "Enter simultaneous IPs; 0 means unlimited"
    opt 4 "Enable account" "Allow this user across Xray protocols"
    opt 5 "Disable account" "Block this user across Xray protocols"
    opt 0 "Cancel" "Return without changes"
    menu_choice "Select an option:" || return
    what=$MENU_CHOICE
    case $what in
        1) read -rp "Add how many days? " v; python3 "$CORE" xray-edit "$u" --days "$v" --extend ;;
        2) read -rp "New quota GB (0=inf): " v; python3 "$CORE" xray-edit "$u" --quota-gb "$v" ;;
        3) read -rp "New IP limit (0=inf): " v; python3 "$CORE" xray-edit "$u" --ip-limit "$v" ;;
        4) python3 "$CORE" xray-edit "$u" --enable ;;
        5) python3 "$CORE" xray-edit "$u" --disable ;;
        0) return ;;
        *) invalid_choice; return ;;
    esac
    pause
}
xray_del() {
    local u a
    page_header "DELETE XRAY ACCOUNT" "Deletion removes this user from all enabled Xray protocols."
    read -rp "Username to delete: " u
    read -rp "Delete '${u:-<not set>}'? [y/N] " a
    case "$a" in y|Y) python3 "$CORE" xray-del "$u" ;; *) echo "No changes made." ;; esac
    pause
}
xray_menu() {
    while true; do
        local stats
        stats=$(python3 "$CORE" stats 2>/dev/null || echo '{}')
        page_header "XRAY ACCOUNTS" "One account provisions VLESS, VMess, Trojan, SSWS and AnyTLS together."
        printf "  Users  VLESS %s  ·  VMess %s  ·  Trojan %s  ·  SSWS %s\n" \
            "$(stats_count vless "$stats")" "$(stats_count vmess "$stats")" \
            "$(stats_count trojan "$stats")" "$(stats_count ssws "$stats")"
        printf "  Xray   %s   Sing-box / AnyTLS   %s\n" "$(svc_dot xray)" "$(svc_dot sing-box)"
        section "ACCOUNT MANAGEMENT"
        opt 1 "Create account" "Enable all supported protocols at once"
        opt 2 "List accounts" "View traffic used, expiry, quota and status"
        opt 3 "Edit / renew account" "Expiry, quota, IP limit or access"
        opt 4 "Delete account" "Remove a user from all protocols"
        opt 5 "Account details" "Usage, limits and live traffic"
        section "SHARE & SERVICE"
        opt 6 "Show all links" "Display links for every enabled protocol"
        opt 7 "Show one protocol link" "VLESS, VMess, Trojan, SSWS or AnyTLS"
        opt 8 "Service status" "Xray, sing-box and HAProxy front door"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) xray_create ;; 2) python3 "$CORE" xray-list; pause ;;
            3) xray_edit ;; 4) xray_del ;; 5) xray_info ;;
            6) xray_links ;; 7) xray_copy_one ;;
            8) systemctl --no-pager status xray sing-box haproxy 2>&1 | sed -n '1,48p'; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}

# ---------------------------------------------------------------------
# UDP ZIVPN / UDP Custom / SlowDNS / Cloudflared
# ---------------------------------------------------------------------
zivpn_edit() {
    local u what v
    read -rp "Username to edit: " u
    page_header "EDIT ZIVPN ACCOUNT" "Update password, expiry or access."
    echo "  Account: ${u:-<not set>}"
    section "ACCOUNT SETTINGS"
    opt 1 "Renew / extend expiry" "Add days to the current expiry"
    opt 2 "Change password" "Password input is hidden"
    opt 3 "Enable account" "Allow UDP ZIVPN access"
    opt 4 "Disable account" "Block UDP ZIVPN access"
    opt 0 "Cancel" "Return without changes"
    menu_choice "Select an option:" || return
    what=$MENU_CHOICE
    case $what in
        1) read -rp "Add how many days? " v; python3 "$CORE" zivpn-edit "$u" --days "$v" --extend ;;
        2) read -rsp "New password: " v; echo; python3 "$CORE" zivpn-edit "$u" --password "$v" ;;
        3) python3 "$CORE" zivpn-edit "$u" --enable ;;
        4) python3 "$CORE" zivpn-edit "$u" --disable ;;
        0) return ;;
        *) invalid_choice; return ;;
    esac
    pause
}
zivpn_menu() {
    while true; do
        page_header "UDP ZIVPN" "Password-based UDP access. Main service listens on UDP 5667."
        printf "  Service : %s   Endpoint : %s:5667/udp\n" "$(svc_dot zivpn)" "$(server_ip)"
        section "ACCOUNTS"
        opt 1 "Create user" "Add a password and expiry"
        opt 2 "List users" "Review usernames and expiry dates"
        opt 3 "Edit / renew user" "Extend expiry, change password or toggle access"
        opt 4 "Delete user" "Remove one ZIVPN account"
        section "SERVICE"
        opt 5 "Server details" "Port and redirect range"
        opt 6 "Restart service" "Apply the current ZIVPN configuration"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) read -rp "Name: " u; read -rsp "Password: " p; echo; read -rp "Days: " d
               python3 "$CORE" zivpn-add "$u" "$p" "${d:-30}"; pause ;;
            2) python3 "$CORE" zivpn-list; pause ;;
            3) zivpn_edit ;;
            4) read -rp "Name: " u; python3 "$CORE" zivpn-del "$u"; pause ;;
            5) echo "Server : $(server_ip):5667 (UDP, range 6000-19999 redirected)"
               echo "Obfs   : zivpn   -   passwords are per-user, see list"; pause ;;
            6) systemctl restart zivpn; echo restarted; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}
udpcustom_menu() {
    while true; do
        page_header "UDP CUSTOM" "UDP forwarding uses the same credentials as your SSH accounts."
        printf "  UDP Custom : %s   BadVPN gateway : %s\n" "$(svc_dot udp-custom)" "$(svc_dot badvpn-udpgw)"
        echo "  UDP range : 1-65535 (panel ports excluded) → 127.0.0.1:36712"
        echo "  Gateway   : badvpn-udpgw at 127.0.0.1:7300"
        section "SERVICE ACTIONS"
        opt 1 "Restart UDP services" "Restart UDP Custom and BadVPN gateway"
        opt 2 "View service log" "Inspect recent UDP Custom status"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) systemctl restart udp-custom badvpn-udpgw; echo restarted; pause ;;
            2) systemctl --no-pager status udp-custom | head -20; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}
slowdns_menu() {
    # SlowDNS is the other panel's implementation, integrated:
    # core/slowdns-setup.sh (their turbo build/NAT/CF/unit code),
    # config in settings.json, keys in $RAGNAR_DIR/slowdns/.
    local SD="$RAGNAR_DIR/slowdns"
    while true; do
        page_header "SLOWDNS / DNSTT" "DNS-tunnel settings and diagnostics. Changes update the service configuration."
        local sd_fields ns pub mtu resolver target
        sd_fields=$(python3 - "$RAGNAR_DIR/settings.json" <<'PY' 2>/dev/null
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    s = {}
print("\x1f".join(str(x) if x is not None else "" for x in [
    s.get("ns", ""),
    s.get("slowdns_pubkey", ""),
    s.get("slowdns_mtu", 1232),
    s.get("slowdns_resolver", ""),
    s.get("slowdns_target", 22),
]))
PY
)
        IFS=$'\x1f' read -r ns pub mtu resolver target <<<"$sd_fields"
        mtu=${mtu:-1232}; target=${target:-22}
        echo "Nameserver : ${ns:-not set}"
        echo "Public key : ${pub:-not generated}"
        echo "Endpoint   : UDP 53 -> dnstt 127.0.0.1:5300 -> SSH 127.0.0.1:$target"
        echo "MTU        : $mtu"
        if [ -n "$resolver" ]; then
            case "$resolver" in
                \[*\]:*) ;;
                \[*\]) resolver="$resolver:53" ;;
                *:*:*) resolver="[$resolver]:53" ;;
                *:*) ;;
                *) resolver="$resolver:53" ;;
            esac
            echo "Resolver   : $resolver (client setting)"
        else
            echo "Resolver   : 1.1.1.1:53 (default)"
        fi
        if [ -x /usr/local/bin/dnstt-server ]; then
            echo "Build      : dnstt-server (turbo patch $([ -f "$SD/.turbo_kcp_patched" ] && echo ACTIVE || echo "not applied - use option 7"))"
        else
            echo "Build      : NOT INSTALLED (use option 1 or 7)"
        fi
        echo "Tip: MTU is a maximum. Replies adapt to the resolver's limit."
        echo "     1232 is recommended to avoid UDP fragmentation."
        section "CONFIGURATION"
        opt 1 "Set nameserver & start" "Optionally create DNS records with Cloudflare"
        opt 2 "Run diagnostics" "Check UDP listener and NS delegation"
        opt 3 "Change SSH backend" "OpenSSH :22 or Dropbear :109"
        opt 4 "Set resolver" "Suggest an endpoint for clients; does not restrict access"
        opt 5 "Set MTU" "1232 is the safest default"
        opt 6 "Regenerate keys" "Create a new server key pair"
        opt 7 "Apply Turbo preset" "Rebuild and use Dropbear; keep the configured MTU"
        section "SERVICE"
        opt 8 "Restart SlowDNS" "Restart with the current settings"
        opt 9 "Stop SlowDNS" "Stop and disable the service"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) read -rp "Nameserver (e.g. ns.yourdomain.com): " v
               [ -z "$v" ] && { echo "Nameserver cannot be empty"; pause; continue; }
               read -rsp "Cloudflare API token (optional, Enter to skip): " tok; echo
               RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$v" "$tok" "$mtu" "" "$target"
               pause ;;
            2) echo "1. dnstt listener on UDP 5300:"
               if ss -ulnp | grep -q ":5300"; then echo "   OK - listening"
               else echo "   NOT listening - restarting via setup"; RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "$mtu" "" "$target"; fi
               echo "2. NS delegation for ${ns:-<unset>} (via Google DNS):"
               if [ -n "$ns" ]; then
                   curl -fsSL "https://dns.google/resolve?name=${ns}&type=NS" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    ans=[a['data'] for a in d.get('Answer',[]) if a.get('type')==2]
    print('   NS ->', ans[0] if ans else 'NOT FOUND - create the NS record in Cloudflare')
except Exception:
    print('   could not check (no network?)')
" || echo "   could not check"
               fi
               pause ;;
            3) echo "Backend: 1) OpenSSH 22   2) Dropbear 109 (lighter handshake)"
               read -rp "Choice [1-2]: " b
               if [ "$b" = "2" ]; then t=109; else t=22; fi
               if RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "$mtu" "" "$t"; then
                   echo "Backend now 127.0.0.1:$t"
               fi
               pause ;;
            4) read -rp "Client resolver (e.g. 1.1.1.1, [2606:4700:4700::1111]:53, or this VPS IP): " v
               [ -n "$v" ] && RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "$mtu" "$v" "$target"
               pause ;;
            5) read -rp "Maximum DNS reply size (512-4096, default 1232): " v
               v=${v:-1232}
               RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "$v" "" "$target"
               pause ;;
            6) rm -f "$SD/server.key" "$SD/server.pub" /etc/vps-panel/slowdns/server.key /etc/vps-panel/slowdns/server.pub
               RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh"
               echo "New public key: $(cat "$SD/server.pub" 2>/dev/null)"
               pause ;;
            7) if RAGNAR_DIR="$RAGNAR_DIR" SLOWDNS_REBUILD=1 bash "$RAGNAR_DIR/core/slowdns-setup.sh" "" "" "" "" "109"; then
                   echo "Turbo preset applied: rebuilt binary and selected Dropbear; kept MTU $mtu"
               fi
               pause ;;
            8) systemctl restart slowdns && echo restarted; pause ;;
            9) systemctl stop slowdns; systemctl disable slowdns 2>/dev/null; echo stopped; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}
cloudflared_menu() {
    while true; do
        page_header "CLOUDFLARE" "Manage domain settings, link hostnames and the optional tunnel."
        printf "  Tunnel service : %s\n" "$(svc_dot_cf)"
        echo "Cloudflare carries the WS protocols (VLESS/VMESS/Trojan/SSWS/SSH-WS)"
        echo "on ports 80 and 443. AnyTLS is raw TLS and stays direct (CF proxy"
        echo "cannot carry it - that is a Cloudflare limit, not a panel limit)."
        section "DOMAIN & TUNNEL"
        opt 1 "Set domain" "TLS certificates and generated links"
        opt 2 "Set Cloudflare link host" "Hostname used in share links"
        opt 3 "Install tunnel token" "Configure and enable cloudflared"
        opt 4 "Start quick tunnel" "Temporary trycloudflare hostname"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) read -rp "Domain: " v
               python3 "$CORE" set-domain "$v" && echo "saved"; pause ;;
            2) read -rp "CF hostname: " v
               python3 - "$v" <<'PY'
import json,sys,os
p=os.path.join(os.environ.get("RAGNAR_DIR","/etc/ragnar"),"settings.json")
s=json.load(open(p)) if os.path.exists(p) else {}
s["cf_host"]=sys.argv[1]
json.dump(s,open(p,"w"),indent=2)
print("saved")
PY
               pause ;;
            3) read -rsp "Tunnel token: " v; echo
               [ -n "$v" ] || { echo "No token entered; no changes made."; pause; continue; }
               systemctl stop cloudflared 2>/dev/null
               cloudflared service install "$v" && systemctl enable --now cloudflared
               pause ;;
            4) echo "Starting quick tunnel - the https hostname appears in the log."
               echo "Point it at http://127.0.0.1:80 (the HAProxy front door)."
               echo "Press Ctrl+C to stop the quick tunnel and return to the menu."
               trap ':' INT
               cloudflared tunnel --url http://127.0.0.1:80 2>&1
               trap - INT
               pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}

# ---------------------------------------------------------------------
# Web panel (3x-ui style, HTTPS on port 2053)
# ---------------------------------------------------------------------
webpanel_menu() {
    while true; do
        page_header "WEB PANEL" "Open the browser UI or manage its service and administrator account."
        local dom url
        dom=$(python3 -c "import json;print(json.load(open('$RAGNAR_DIR/settings.json')).get('domain',''))" 2>/dev/null)
        [ -z "$dom" ] && dom=$(server_ip)
        url="https://$dom/panel"
        echo "URL     : $url"
        printf "Service : %s\n" "$(svc_dot ragnar-web)"
        echo "Log in with the admin username/password (set at install;"
        echo "reset it below if you lost it)."
        opt 1 "Service status" "Show recent service details"
        opt 2 "Reset admin password" "Set a new password for the web UI"
        opt 3 "Restart web panel" "Restart the local web service"
        opt 4 "Toggle service" "Start or stop the web panel"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) echo "Open: $url"; systemctl --no-pager status ragnar-web | head -12; pause ;;
            2) python3 "$RAGNAR_DIR/web/webpanel.py" --reset-password; pause ;;
            3) systemctl restart ragnar-web; echo restarted; pause ;;
            4) if systemctl is-active --quiet ragnar-web; then
                   systemctl stop ragnar-web; echo stopped
               else systemctl start ragnar-web; echo started; fi; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}

# ---------------------------------------------------------------------
# Tools / status
# ---------------------------------------------------------------------
tools_menu() {
    while true; do
        page_header "TOOLS & DIAGNOSTICS" "Maintenance actions and quick checks for this VPS."
        section "MAINTENANCE"
        opt 1 "Restart panel services" "Connected users may be briefly interrupted"
        opt 2 "Back up panel data" "Create a dated archive under /root"
        opt 3 "Run limit checker" "Apply expiry, quota and IP-limit rules"
        section "DIAGNOSTICS"
        opt 4 "Speed test" "Measure a short download sample"
        opt 5 "Listening ports" "Show key ports and owning processes"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) systemctl restart haproxy xray sing-box ragnar-wsproxy dropbear \
                   zivpn udp-custom badvpn-udpgw slowdns ragnar-web 2>/dev/null; echo done; pause ;;
            2) local f="/root/ragnar-backup-$(date +%F-%H%M).tar.gz"
               tar -czf "$f" -C "$RAGNAR_DIR" db settings.json 2>/dev/null && echo "Saved: $f"; pause ;;
            3) /usr/local/bin/ragnar-check --apply 2>/dev/null || \
               python3 "$RAGNAR_DIR/core/checker.py" --apply; pause ;;
            4) curl -s -o /dev/null -w "Download: %{speed_download} B/s\n" \
                   --max-time 15 https://speed.cloudflare.com/__down?bytes=25000000; pause ;;
            5) ss -tulnp | grep -E ':(80|443|22|109|5667|36712|53|7300|8446)\b'; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}
update_panel() {
    print_header; bar "UPDATE PANEL"
    echo -e "${W}The panel updates itself from GitHub (main branch).${N}"
    echo -e "${W}Users, settings, certificates and SlowDNS keys are kept;${N}"
    echo -e "${W}a backup of the current state is saved to /root first.${N}"
    echo
    bash "$RAGNAR_DIR/core/update.sh" check || true
    echo
    read -rp "Update / reinstall latest panel files now? [y/N] " a
    case "$a" in
        y|Y|yes|YES)
            if bash "$RAGNAR_DIR/core/update.sh" --force; then
                hash -r 2>/dev/null || true
                echo; echo "Reloading the menu with the new version..."
                sleep 1; exec bash "$RAGNAR_DIR/menu.sh"
            fi
            ;;
    esac
    pause
}
status_page() {
    page_header "STATUS & HEALTH" "Current service state, bandwidth and listening ports."
    local -a units=(haproxy xray sing-box ragnar-wsproxy dropbear ssh zivpn udp-custom \
                    badvpn-udpgw slowdns cloudflared ragnar-web ragnar-check.timer ragnar-watchdog.timer)
    local -a states=()
    mapfile -t states < <(systemctl is-active "${units[@]}" 2>/dev/null || true)
    local i st_txt
    for i in "${!units[@]}"; do
        if [ "${states[$i]:-inactive}" = "active" ]; then
            st_txt="${G}● ONLINE${N}"
        else
            st_txt="${R}● OFFLINE${N}"
        fi
        printf "  ${C}%-24s${W}: %b\n" "${units[$i]}" "$st_txt"
    done
    echo; bar "BANDWIDTH"; bandwidth_lines
    echo; ss -tulnp 2>/dev/null | grep -E ':(80|443|22|109|5667|36712|53|8446)\b' || true
    pause
}

# ---------------------------------------------------------------------
if [ "${RAGNAR_PREVIEW:-}" = "1" ]; then
    print_header; main_menu; exit 0
fi

while true; do
    print_header; main_menu
    read -rp "Select menu: " opt
    case $opt in
        1) ssh_menu ;;
        2) xray_menu ;;
        3) zivpn_menu ;;
        4) udpcustom_menu ;;
        5) slowdns_menu ;;
        6) cloudflared_menu ;;
        7) webpanel_menu ;;
        8) status_page ;;
        9) tools_menu ;;
        10) update_panel ;;
        11) sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; echo "RAM cleared"; pause ;;
        12) read -rp "Reboot the VPS now? [y/N] " a; [ "$a" = y ] && reboot ;;
        13) read -rp "UNINSTALL Ragnar Panel completely? [y/N] " a
            [ "$a" = y ] && bash "$RAGNAR_DIR/uninstall.sh" ;;
        x|X) clear_screen; echo "Bye - @farisbazed / https://t.me/ragnaresim"; exit 0 ;;
        *) invalid_choice ;;
    esac
done
