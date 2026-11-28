#!/bin/bash
# =====================================================================
# Ragnar VPS Management Panel - main menu
# Telegram : @farisbazed
# Channel  : https://t.me/ragnaresim
# =====================================================================
RAGNAR_DIR="${RAGNAR_DIR:-/etc/ragnar}"
menu_path=${BASH_SOURCE[0]}
if [[ -L $menu_path ]]; then menu_path=$(readlink -f -- "$menu_path"); fi
DIR="$(cd "$(dirname "$menu_path")" && pwd)"
CORE="${RAGNAR_CORE:-$RAGNAR_DIR/core/ragnar.py}"
[ -f "$CORE" ] || CORE="$DIR/core/ragnar.py"
export RAGNAR_DIR

# ---- terminal UI -----------------------------------------------------
source "$DIR/core/terminal-theme.sh" || { return 1 2>/dev/null || exit 1; }
theme_load

term_width() {
    local width=${COLUMNS:-}
    if [[ -t 2 || -z $width ]]; then width=$(tput cols 2>/dev/null); fi
    [[ $width =~ ^[1-9][0-9]{0,3}$ ]] || width=80
    (( width > 96 )) && width=96
    printf '%d\n' "$width"
}
clear_screen() { [[ -t 1 && ${TERM:-dumb} != dumb ]] && clear 2>/dev/null || true; }

ui_repeat() {
    local _out=$1 _n=$2 _ch=$3 _buf=''
    (( _n > 0 )) && printf -v _buf '%*s' "$_n" ''
    printf -v "$_out" '%s' "${_buf// /$_ch}"
}
ui_box_close() {
    [[ ${UI_BOX_OPEN:-0} == 1 ]] || return 0
    local rule
    ui_repeat rule "$((UI_COLS - 2))" '─'
    printf '%s╰%s╯%s\n' "$DIM" "$rule" "$N"
    UI_BOX_OPEN=0
}
ui_box_row() {
    local vis=$1 content=$2 inner=$((UI_COLS - 4)) pad
    if (( vis <= inner )); then
        pad=$((inner - vis))
        printf '%s│%s %s%*s %s│%s\n' "$DIM" "$N" "$content" "$pad" '' "$DIM" "$N"
    else
        printf '%s│%s %s\n' "$DIM" "$N" "$content"
    fi
}
ui_prompt_prefix() {
    case "${LAYOUT:-classic}" in
        boxed) printf '  %s╰─%s›%s ' "$DIM" "$C" "$N" ;;
        compact) printf '  %s»%s ' "$C" "$N" ;;
        ledger) printf '  %s[>]%s ' "$C" "$N" ;;
        *) printf '  %s›%s ' "$C" "$N" ;;
    esac
}

# Wrap prose at words. A long single token (e.g. a public key) stays
# intact for copying and gets the terminal's own soft wrapping.
paragraph() {
    local content=$1 color=${2:-} indent=${3:-2} word line='' extra=0 limit=$UI_COLS
    local -a words
    read -ra words <<<"$content"
    if [[ ${LAYOUT:-classic} == boxed && ${UI_BOX_OPEN:-0} == 1 ]]; then
        (( indent > 2 )) && extra=$((indent - 2))
        limit=$((UI_COLS - 4 - extra))
        for word in "${words[@]}"; do
            if [[ -n $line ]] && (( ${#line} + 1 + ${#word} > limit )); then
                ui_box_row "$((extra + ${#line}))" "$(printf '%*s%s%s%s' "$extra" '' "$color" "$line" "$N")"
                line=''
            fi
            line="${line:+$line }$word"
        done
        ui_box_row "$((extra + ${#line}))" "$(printf '%*s%s%s%s' "$extra" '' "$color" "$line" "$N")"
        return 0
    fi
    for word in "${words[@]}"; do
        if [[ -n $line ]] && (( indent + ${#line} + 1 + ${#word} > UI_COLS )); then
            printf '%*s%s%s%s\n' "$indent" '' "$color" "$line" "$N"
            line=''
        fi
        line="${line:+$line }$word"
    done
    printf '%*s%s%s%s\n' "$indent" '' "$color" "$line" "$N"
}
section() {
    local title=$1 rule='' span
    case "${LAYOUT:-classic}" in
        boxed)
            ui_box_close
            span=$((UI_COLS - ${#title} - 5))
            (( span > 0 )) && ui_repeat rule "$span" '─'
            printf '\n%s╭─ %s%s%s%s%s %s╮%s\n' "$DIM" "$C" "$B" "$title" "$N" "$DIM" "$rule" "$N"
            UI_BOX_OPEN=1 ;;
        compact)
            span=$((UI_COLS - ${#title} - 6))
            printf '\n  %s▸ %s%s%s' "$C" "$B" "$title" "$N"
            if (( span > 0 )); then
                ui_repeat rule "$span" '╌'
                printf '  %s%s%s' "$DIM" "$rule" "$N"
            fi
            printf '\n' ;;
        ledger)
            span=$((UI_COLS - ${#title} - 6))
            (( span > 0 )) && ui_repeat rule "$span" '═'
            printf '\n%s══╡ %s%s%s%s%s ╞%s%s\n' "$DIM" "$C" "$B" "$title" "$N" "$DIM" "$rule" "$N" ;;
        *)
            span=$((UI_COLS - ${#title} - 4))
            printf '\n  %s%s%s%s' "$C" "$B" "$title" "$N"
            if (( span > 0 )); then
                ui_repeat rule "$span" '─'
                printf '  %s%s%s' "$DIM" "$rule" "$N"
            fi
            printf '\n' ;;
    esac
}
masthead() {
    local title=$1 host=$2 brand='VPS CONSOLE' rule='' inner gap
    UI_COLS=$(term_width)
    UI_BOX_OPEN=0
    printf '%s' "$CANVAS"
    clear_screen
    case "${LAYOUT:-classic}" in
        boxed)
            inner=$((UI_COLS - 4))
            ui_repeat rule "$((UI_COLS - 2))" '─'
            printf '%s╭%s╮%s\n' "$DIM" "$rule" "$N"
            if (( 21 + 2 + ${#host} <= inner )); then
                gap=$((inner - 21 - ${#host}))
                ui_box_row "$inner" "$(printf '%s RAGNAR %s  %s%s%s%*s%s%s%s' "$BADGE" "$N" "$DIM" "$brand" "$N" "$gap" '' "$DIM" "$host" "$N")"
            elif (( 8 + 2 + ${#host} <= inner )); then
                gap=$((inner - 8 - ${#host}))
                ui_box_row "$inner" "$(printf '%s RAGNAR %s%*s%s%s%s' "$BADGE" "$N" "$gap" '' "$DIM" "$host" "$N")"
            else
                ui_box_row 8 "$(printf '%s RAGNAR %s' "$BADGE" "$N")"
                ui_box_row "${#host}" "$(printf '%s%s%s' "$DIM" "$host" "$N")"
            fi
            ui_box_row "${#title}" "$(printf '%s%s%s' "$B" "$title" "$N")"
            printf '%s╰%s╯%s\n' "$DIM" "$rule" "$N" ;;
        compact)
            printf '  %s RAGNAR %s  %s%s%s' "$BADGE" "$N" "$B" "$title" "$N"
            if (( 12 + ${#title} + 2 + ${#host} <= UI_COLS )); then
                printf '%*s%s%s%s\n' "$((UI_COLS - 12 - ${#title} - ${#host}))" '' "$DIM" "$host" "$N"
            else
                printf '\n'; paragraph "$host" "$DIM"
            fi
            ui_repeat rule "$UI_COLS" '═'
            printf '%s%s%s\n' "$DIM" "$rule" "$N" ;;
        ledger)
            inner=$((UI_COLS - 4))
            ui_repeat rule "$((UI_COLS - 2))" '═'
            printf '%s╔%s╗%s\n' "$DIM" "$rule" "$N"
            if (( 21 + 8 + ${#host} <= inner )); then
                gap=$((inner - 27 - ${#host}))
                printf '%s║%s %s%sRAGNAR%s %s// %s%s%*s%sHOST: %s%s %s║%s\n' \
                    "$DIM" "$N" "$C" "$B" "$N" "$DIM" "$brand" "$N" "$gap" '' "$DIM" "$N" "$host" "$DIM" "$N"
            elif (( 6 + 2 + ${#host} <= inner )); then
                gap=$((inner - 6 - ${#host}))
                printf '%s║%s %s%sRAGNAR%s%*s%s%s%s %s║%s\n' \
                    "$DIM" "$N" "$C" "$B" "$N" "$gap" '' "$DIM" "$host" "$N" "$DIM" "$N"
            else
                gap=$((inner - 6))
                printf '%s║%s %s%sRAGNAR%s%*s %s║%s\n' "$DIM" "$N" "$C" "$B" "$N" "$gap" '' "$DIM" "$N"
                gap=$((inner - ${#host}))
                if (( gap >= 0 )); then
                    printf '%s║%s %s%s%s%*s %s║%s\n' "$DIM" "$N" "$DIM" "$host" "$N" "$gap" '' "$DIM" "$N"
                else
                    printf '%s║%s %s%s%s\n' "$DIM" "$N" "$DIM" "$host" "$N"
                fi
            fi
            printf '%s╠%s╣%s\n' "$DIM" "$rule" "$N"
            gap=$((inner - 2 - ${#title}))
            if (( gap >= 0 )); then
                printf '%s║%s %s»%s %s%s%s%*s %s║%s\n' "$DIM" "$N" "$C" "$N" "$B" "$title" "$N" "$gap" '' "$DIM" "$N"
            else
                printf '%s║%s %s»%s %s%s%s\n' "$DIM" "$N" "$C" "$N" "$B" "$title" "$N"
            fi
            printf '%s╚%s╝%s\n' "$DIM" "$rule" "$N" ;;
        *)
            printf '  %s RAGNAR %s  %s%s%s' "$BADGE" "$N" "$DIM" "$brand" "$N"
            if (( 26 + ${#host} <= UI_COLS )); then
                printf '%*s%s%s%s\n' "$((UI_COLS - 23 - ${#host}))" '' "$DIM" "$host" "$N"
            else
                printf '\n'; paragraph "$host" "$DIM"
            fi
            printf '\n  %s%s%s\n' "$B" "$title" "$N" ;;
    esac
}
page_header() {
    masthead "$1" "$(server_ip)"
    [[ -z ${2:-} ]] || paragraph "$2" "$DIM"
}
kv() {
    local label=$1 value=$2 color=${3:-} lw=12
    (( ${#label} > lw )) && lw=${#label}
    if [[ ${LAYOUT:-classic} == boxed && ${UI_BOX_OPEN:-0} == 1 ]]; then
        if (( lw + 2 + ${#value} <= UI_COLS - 4 )); then
            ui_box_row "$((lw + 2 + ${#value}))" "$(printf '%s%-*s%s  %s%s%s' "$DIM" "$lw" "$label" "$N" "$color" "$value" "$N")"
        else
            ui_box_row "${#label}" "$(printf '%s%s%s' "$DIM" "$label" "$N")"
            paragraph "$value" "$color" 4
        fi
        return 0
    fi
    if [[ ${LAYOUT:-classic} == ledger ]]; then
        if (( 2 + lw + 3 + ${#value} <= UI_COLS )); then
            printf '  %s%-*s%s %s:%s %s%s%s\n' "$DIM" "$lw" "$label" "$N" "$DIM" "$N" "$color" "$value" "$N"
        else
            printf '  %s%s:%s\n' "$DIM" "$label" "$N"
            paragraph "$value" "$color" 4
        fi
        return 0
    fi
    if (( 2 + lw + 2 + ${#value} <= UI_COLS )); then
        printf '  %s%-*s%s  %s%s%s\n' "$DIM" "$lw" "$label" "$N" "$color" "$value" "$N"
    else
        printf '  %s%s%s\n' "$DIM" "$label" "$N"
        paragraph "$value" "$color" 4
    fi
}
# Format status values for non-classic layouts without changing underlying data.
ui_fact_display() {
    local val=$1
    case "${LAYOUT:-classic}:$val" in
        compact:Online) printf '● Online' ;;
        compact:Offline) printf '○ Offline' ;;
        'compact:No tunnel') printf '◌ No tunnel' ;;
        ledger:Online|ledger:Offline|'ledger:No tunnel') printf '[%s]' "$val" ;;
        *) printf '%s' "$val" ;;
    esac
}
# Fit complete label/value pairs to the row; never crop a value.
facts() {
    local label value disp style i cell=0 keylen=0 pos=0 cols rows count=$(( $# / 2 ))
    local avail=$UI_COLS lead=2 sep='   ' sep_vis=3 row_vis=0 row_txt='' piece pad
    local -a args=("$@") disps=()
    if [[ ${LAYOUT:-classic} == boxed && ${UI_BOX_OPEN:-0} == 1 ]]; then
        avail=$((UI_COLS - 4)); lead=0
    elif [[ ${LAYOUT:-classic} == ledger ]]; then
        sep=" ${DIM}│${N} "
    fi
    for ((i=0; i<${#args[@]}; i+=2)); do
        label=${args[i]}; value=${args[i+1]}
        disp=$(ui_fact_display "$value")
        disps+=("$disp")
        (( ${#label} > keylen )) && keylen=${#label}
        (( ${#disp} > cell )) && cell=${#disp}
    done
    local val_max=$cell
    cell=$((keylen + 2 + val_max + sep_vis))
    cols=$(( (avail - lead + sep_vis) / cell ))
    (( cols > 4 )) && cols=4
    (( cols < 1 )) && cols=1
    rows=$(( (count + cols - 1) / cols ))
    (( rows )) || return 0
    cols=$(( (count + rows - 1) / rows ))
    local idx=0
    while (( $# )); do
        label=$1; value=$2; shift 2
        disp=${disps[idx]}; idx=$((idx + 1))
        case "$value" in
            Online) style=$G ;; Offline) style=$R ;; 'No tunnel') style=$Y ;; *) style=$B ;;
        esac
        if (( lead + keylen + 2 + ${#disp} > avail )); then
            if (( pos > 0 )); then
                if [[ ${LAYOUT:-classic} == boxed && ${UI_BOX_OPEN:-0} == 1 ]]; then
                    ui_box_row "$row_vis" "$row_txt"; row_vis=0; row_txt=''
                else
                    printf '\n'
                fi
                pos=0
            fi
            kv "$label" "$disp" "$style"; continue
        fi
        printf -v piece '%s%-*s%s  %s%s%s' "$DIM" "$keylen" "$label" "$N" "$style" "$disp" "$N"
        if [[ ${LAYOUT:-classic} == boxed && ${UI_BOX_OPEN:-0} == 1 ]]; then
            row_txt+="$piece"
            row_vis=$((row_vis + keylen + 2 + ${#disp}))
            pos=$((pos + 1))
            if (( $# && pos < cols )); then
                pad=$((cell - keylen - 2 - ${#disp}))
                printf -v piece '%*s' "$pad" ''
                row_txt+="$piece"; row_vis=$((row_vis + pad))
            else
                ui_box_row "$row_vis" "$row_txt"
                row_vis=0; row_txt=''; pos=0
            fi
        else
            printf '%*s%s' "$((pos == 0 ? lead : 0))" '' "$piece"
            pos=$((pos + 1))
            if (( $# && pos < cols )); then
                pad=$((cell - keylen - 2 - ${#disp} - sep_vis))
                (( pad > 0 )) && printf '%*s' "$pad" ''
                printf '%s' "$sep"
            else
                printf '\n'; pos=0
            fi
        fi
    done
}
opt() {
    local key=$1 label=$2 detail=${3:-} ink=$C
    local inner kstr kvis dots dotstr row
    [[ ${4:-} != warn ]] || ink=$Y
    case "${LAYOUT:-classic}" in
        boxed)
            case "$key" in
                0|x)
                    ui_box_close
                    ink=$DIM
                    printf '  %s[%s%s%2s%s%s]%s %s' "$DIM" "$ink" "$B" "$key" "$N" "$DIM" "$N" "$label"
                    if [[ -n $detail ]] && (( UI_COLS >= 68 && ${#label} <= 26 && 35 + ${#detail} <= UI_COLS )); then
                        printf '%*s%s%s%s' "$((28 - ${#label}))" '' "$DIM" "$detail" "$N"
                    fi
                    printf '\n'
                    return 0 ;;
            esac
            if [[ ${UI_BOX_OPEN:-0} == 1 ]]; then
                inner=$((UI_COLS - 4))
                if (( 5 + ${#label} <= inner )); then
                    printf -v kstr '%s[%s%s%2s%s%s]%s ' "$DIM" "$ink" "$B" "$key" "$N" "$DIM" "$N"
                    kvis=5
                else
                    printf -v kstr '%s[%s%s%s%s%s]%s ' "$DIM" "$ink" "$B" "$key" "$N" "$DIM" "$N"
                    kvis=$((3 + ${#key}))
                fi
                if [[ -n $detail ]] && (( UI_COLS >= 68 && kvis + ${#label} + 4 + ${#detail} <= inner )); then
                    dots=$((inner - kvis - ${#label} - 2 - ${#detail}))
                    ui_repeat dotstr "$dots" '·'
                    printf -v row '%s%s %s%s %s%s' "$kstr" "$label" "$DIM" "$dotstr" "$detail" "$N"
                    ui_box_row "$inner" "$row"
                else
                    ui_box_row "$((kvis + ${#label}))" "${kstr}${label}"
                fi
                return 0
            fi ;;
        compact)
            case "$key" in 0|x) printf '\n'; ink=$DIM ;; esac
            printf '  %s[%s%s%2s%s%s]%s %s' "$DIM" "$ink" "$B" "$key" "$N" "$DIM" "$N" "$label"
            if [[ -n $detail ]] && (( UI_COLS >= 68 && ${#label} <= 26 && 35 + ${#detail} <= UI_COLS )); then
                printf '%*s%s%s%s' "$((28 - ${#label}))" '' "$DIM" "$detail" "$N"
            fi
            printf '\n'
            return 0 ;;
        ledger)
            case "$key" in 0|x) printf '\n'; ink=$DIM ;; esac
            printf '  %s%s%2s%s %s│%s %s' "$ink" "$B" "$key" "$N" "$DIM" "$N" "$label"
            if [[ -n $detail ]] && (( UI_COLS >= 68 && ${#label} <= 26 && 38 + ${#detail} <= UI_COLS )); then
                printf '%*s%s:: %s%s' "$((28 - ${#label}))" '' "$DIM" "$detail" "$N"
            fi
            printf '\n'
            return 0 ;;
    esac
    case "$key" in 0|x) printf '\n'; ink=$DIM ;; esac
    printf '  %s%s%2s%s  %s' "$ink" "$B" "$key" "$N" "$label"
    if [[ -n $detail ]] && (( UI_COLS >= 68 && ${#label} <= 26 && 34 + ${#detail} <= UI_COLS )); then
        printf '%*s%s%s%s' "$((28 - ${#label}))" '' "$DIM" "$detail" "$N"
    fi
    printf '\n'
}
menu_choice() {
    local prompt="${1:-Select an option}" prefix
    ui_box_close
    prefix=$(ui_prompt_prefix)
    read -rp "${prefix}${prompt} " MENU_CHOICE || return 1
    case "$MENU_CHOICE" in b|B|back|BACK|q|Q) MENU_CHOICE=0 ;; esac
}
invalid_choice() { ui_box_close; paragraph "Choose one of the listed keys." "$Y"; pause; }
svc_dot() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        printf 'Online'
    else
        printf 'Offline'
    fi
}
svc_dot_cf() {
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        printf 'Online'
    elif systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q cloudflared; then
        printf 'Offline'
    else
        printf 'No tunnel'
    fi
}
pause() { ui_box_close; read -rp "  Enter to continue › " _ || true; }

bandwidth_lines() {
    python3 "$CORE" bandwidth-summary 2>/dev/null \
        | while IFS= read -r l; do paragraph "$l"; done
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

resource_meter() {
    local label=$1 value=$2 size=$(( UI_COLS >= 68 ? 12 : 6 )) pct used fill track tip='' rem row
    case "${LAYOUT:-classic}" in
        boxed)
            (( UI_COLS >= 68 )) && size=14
            if [[ ${UI_BOX_OPEN:-0} == 1 && $value =~ ([0-9]+)(\.[0-9]+)?% ]] && (( 12 + size + ${#value} <= UI_COLS - 4 )); then
                pct=${BASH_REMATCH[1]}
                (( pct > 100 )) && pct=100
                used=$(( (pct * size + 50) / 100 ))
                ui_repeat fill "$used" '▓'; ui_repeat track "$((size - used))" '░'
                printf -v row '%s%-6s%s  %s▕%s%s%s%s%s▏%s  %s' \
                    "$DIM" "$label" "$N" "$DIM" "$C" "$fill" "$DIM" "$track" "$DIM" "$N" "$value"
                ui_box_row "$((12 + size + ${#value}))" "$row"
                return 0
            fi ;;
        compact)
            if [[ $value =~ ([0-9]+)(\.[0-9]+)?% ]] && (( 12 + size + ${#value} <= UI_COLS )); then
                pct=${BASH_REMATCH[1]}
                (( pct > 100 )) && pct=100
                used=$(( (pct * size + 50) / 100 ))
                rem=$((size - used))
                if (( used > 0 && rem > 0 )); then
                    ui_repeat fill "$((used - 1))" '━'; tip='╸'
                else
                    ui_repeat fill "$used" '━'; tip=''
                fi
                ui_repeat track "$rem" '─'
                printf '  %s%-6s%s  %s%s%s%s%s%s  %s\n' "$DIM" "$label" "$N" \
                    "$C" "$fill" "$tip" "$DIM" "$track" "$N" "$value"
                return 0
            fi ;;
        ledger)
            if [[ $value =~ ([0-9]+)(\.[0-9]+)?% ]] && (( 14 + size + ${#value} <= UI_COLS )); then
                pct=${BASH_REMATCH[1]}
                (( pct > 100 )) && pct=100
                used=$(( (pct * size + 50) / 100 ))
                ui_repeat fill "$used" '#'; ui_repeat track "$((size - used))" '-'
                printf '  %s%-6s%s  %s[%s%s%s%s%s]%s  %s\n' "$DIM" "$label" "$N" \
                    "$DIM" "$C" "$fill" "$DIM" "$track" "$DIM" "$N" "$value"
                return 0
            fi ;;
        *)
            if [[ $value =~ ([0-9]+)(\.[0-9]+)?% ]] && (( 12 + size + ${#value} <= UI_COLS )); then
                pct=${BASH_REMATCH[1]}
                (( pct > 100 )) && pct=100
                used=$(( (pct * size + 50) / 100 ))
                ui_repeat fill "$used" '█'; ui_repeat track "$((size - used))" '─'
                printf '  %s%-6s%s  %s%s%s%s%s  %s\n' "$DIM" "$label" "$N" \
                    "$C" "$fill" "$DIM" "$track" "$N" "$value"
                return 0
            fi ;;
    esac
    kv "$label" "$value"
}
read_host_stats() {
    ip=$(server_ip); isp=$(server_isp)
    os=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    up=$(uptime -p 2>/dev/null | sed 's/^up //')
    cpu=$(cpu_usage_pct)
    ram=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {if (t>0) printf "%dMB / %dMB (%.0f%%)", (t-a)/1024, t/1024, (t-a)*100/t}' /proc/meminfo 2>/dev/null)
    disk=$(df -Ph / 2>/dev/null | awk 'NR==2 {if ($2 == "0" || $2 == "0B") printf "%s used", $3; else printf "%s / %s (%s)", $3, $2, $5}')
    now=$(date '+%d-%m-%Y %T')
}

compact_svc_cell() {
    local name=$1 state=$2 sym='●' col=$G
    case "$state" in
        Offline) sym='○'; col=$R ;;
        'No tunnel') sym='◌'; col=$Y ;;
    esac
    printf -v "$3" '%s%s%s %s' "$col" "$sym" "$N" "$name"
    printf -v "$4" '%d' "$((2 + ${#name}))"
}
compact_meter_line() {
    local label=$1 value=$2 maxw=$3 pct used rem fill='' tip='' track='' size=8
    if [[ $value =~ ([0-9]+)(\.[0-9]+)?% ]]; then
        pct=${BASH_REMATCH[1]}; (( pct > 100 )) && pct=100
        if (( 8 + size + 1 + ${#value} > maxw )); then size=6; fi
        if (( 8 + size + 1 + ${#value} <= maxw )); then
            used=$(( (pct * size + 50) / 100 )); rem=$((size - used))
            if (( used > 0 && rem > 0 )); then
                ui_repeat fill "$((used - 1))" '━'; tip='╸'
            else
                ui_repeat fill "$used" '━'; tip=''
            fi
            ui_repeat track "$rem" '─'
            printf -v "$4" '  %s%-5s%s %s%s%s%s%s%s %s' "$DIM" "$label" "$N" "$C" "$fill" "$tip" "$DIM" "$track" "$N" "$value"
            printf -v "$5" '%d' "$((8 + size + 1 + ${#value}))"
            return 0
        fi
    fi
    local val=$value
    if (( 8 + ${#val} > maxw )); then val=${val:0:$((maxw - 8))}; fi
    printf -v "$4" '  %s%-5s%s %s' "$DIM" "$label" "$N" "$val"
    printf -v "$5" '%d' "$((8 + ${#val}))"
}
compact_kv_line() {
    local label=$1 val=$2 maxw=$3
    if (( 8 + ${#val} > maxw )); then val=${val:0:$((maxw - 8))}; fi
    printf -v "$4" '  %s%-5s%s %s%s%s' "$DIM" "$label" "$N" "$B" "$val" "$N"
    printf -v "$5" '%d' "$((8 + ${#val}))"
}
compact_dashboard_body() {
    local lw=$(( (UI_COLS - 3) / 2 )) rw
    rw=$(( UI_COLS - lw - 3 ))
    local -a l_txt=() l_vis=() r_txt=() r_vis=()
    local txt vis c1 v1 c2 v2 half=$(( (rw - 1) / 2 )) pad

    l_txt+=("  ${C}▸ ${B}HOST & RESOURCES${N}"); l_vis+=(20)
    compact_kv_line "ISP" "${isp:-Unknown}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_kv_line "OS" "${os:-Linux}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_kv_line "Up" "${up:-n/a}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_kv_line "Time" "${now:-n/a}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_meter_line "CPU" "${cpu:-n/a}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_meter_line "RAM" "${ram:-n/a}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_meter_line "Disk" "${disk:-n/a}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_kv_line "Today" "${bw_today:-n/a}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    compact_kv_line "Month" "${bw_month:-n/a}" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    if [[ -n ${bw_src:-} ]]; then
        compact_kv_line "Src" "$bw_src" "$lw" txt vis; l_txt+=("$txt"); l_vis+=("$vis")
    fi

    local acc1="Total ${s_total:-0} · Online ${s_online:-0}"
    local acc2="SSH ${s_ssh:-0} · VLESS ${s_vless:-0} · VMess ${s_vmess:-0}"
    local acc3="Trojan ${s_trojan:-0} · SSWS ${s_ssws:-0} · ZIVPN ${s_zivpn:-0}"
    (( ${#acc1} > rw )) && acc1=${acc1:0:$rw}
    (( ${#acc2} > rw )) && acc2=${acc2:0:$rw}
    (( ${#acc3} > rw )) && acc3=${acc3:0:$rw}
    r_txt+=("${C}▸ ${B}ACCOUNTS${N}"); r_vis+=(10)
    r_txt+=("${B}${acc1}${N}"); r_vis+=("${#acc1}")
    r_txt+=("${DIM}${acc2}${N}"); r_vis+=("${#acc2}")
    r_txt+=("${DIM}${acc3}${N}"); r_vis+=("${#acc3}")
    r_txt+=("${C}▸ ${B}SERVICES${N}"); r_vis+=(10)

    local -a svc_pairs=(
        "Xray" "${svc_map[xray]}" "HAProxy" "${svc_map[haproxy]}"
        "Dropbear" "${svc_map[dropbear]}" "sing-box" "${svc_map[sing-box]}"
        "UDP Custom" "${svc_map[udp-custom]}" "ZIVPN" "${svc_map[zivpn]}"
        "SSH WS" "${svc_map[ragnar-wsproxy]}" "WSS / SSL" "${svc_map[haproxy]}"
        "SlowDNS" "${svc_map[slowdns]}" "BadVPN" "${svc_map[badvpn-udpgw]}"
        "cloudflared" "${svc_map[cloudflared]}" "Web panel" "${svc_map[ragnar-web]}"
    )
    local idx
    for ((idx=0; idx<${#svc_pairs[@]}; idx+=4)); do
        compact_svc_cell "${svc_pairs[idx]}" "${svc_pairs[idx+1]}" c1 v1
        compact_svc_cell "${svc_pairs[idx+2]}" "${svc_pairs[idx+3]}" c2 v2
        pad=$((half - v1)); (( pad < 1 )) && pad=1
        printf -v txt '%s%*s%s' "$c1" "$pad" '' "$c2"
        r_txt+=("$txt"); r_vis+=("$((v1 + pad + v2))")
    done

    local total=${#l_txt[@]} i lpad
    (( ${#r_txt[@]} > total )) && total=${#r_txt[@]}
    for ((i=0; i<total; i++)); do
        lpad=$((lw - ${l_vis[i]:-0})); (( lpad < 0 )) && lpad=0
        printf '%s%*s %s│%s %s\n' "${l_txt[i]:-}" "$lpad" '' "$DIM" "$N" "${r_txt[i]:-}"
    done
    local lr rr
    ui_repeat lr "$((lw + 1))" '─'; ui_repeat rr "$((rw + 1))" '─'
    printf '%s%s┴%s%s\n' "$DIM" "$lr" "$rr" "$N"
}
compact_menu_pair() {
    local lw=$1 lk=$2 ll=$3 lwarn=$4 rk=$5 rl=$6 rwarn=$7
    local li=$C ri=$C lstr='' lvis=0 rstr='' pad
    [[ $lwarn == warn ]] && li=$Y
    [[ $lwarn == dim ]] && li=$DIM
    [[ $rwarn == warn ]] && ri=$Y
    [[ $rwarn == dim ]] && ri=$DIM
    if [[ -n $lk ]]; then
        printf -v lstr '  %s[%s%s%2s%s%s]%s %s' "$DIM" "$li" "$B" "$lk" "$N" "$DIM" "$N" "$ll"
        lvis=$((7 + ${#ll}))
    elif [[ -n $ll ]]; then
        lstr="  ${C}▸ ${B}${ll}${N}"
        lvis=$((4 + ${#ll}))
    fi
    if [[ -n $rk ]]; then
        printf -v rstr '%s[%s%s%2s%s%s]%s %s' "$DIM" "$ri" "$B" "$rk" "$N" "$DIM" "$N" "$rl"
    elif [[ -n $rl ]]; then
        if [[ $rwarn == dim ]]; then
            rstr="${DIM}${rl}${N}"
        else
            rstr="${C}▸ ${B}${rl}${N}"
        fi
    fi
    if [[ -z $rstr ]]; then
        printf '%s\n' "$lstr"
        return 0
    fi
    pad=$((lw - lvis)); (( pad < 1 )) && pad=1
    printf '%s%*s   %s\n' "$lstr" "$pad" '' "$rstr"
}

print_header() {
    local ip isp os up cpu ram disk now
    read_host_stats
    masthead "Server overview" "${ip:-n/a}"

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
print("\x1f".join(str(x) for x in [
    t, m, src if src != "vnstat" else "",
    st.get("vmess", 0), st.get("vless", 0), st.get("trojan", 0),
    st.get("ssws", 0), st.get("ssh", 0), st.get("zivpn", 0),
    st.get("total", 0), on.get("online", 0)
]))
PY
)
    IFS=$'\x1f' read -r bw_today bw_month bw_src s_vmess s_vless s_trojan s_ssws s_ssh s_zivpn s_total s_online <<<"$dash_tsv"

    # Single batched systemctl call for all header services
    local -a units=(xray haproxy dropbear sing-box udp-custom zivpn ragnar-wsproxy slowdns badvpn-udpgw ragnar-web cloudflared dnstm-dnsrouter dnstm-slip1)
    local -a states=()
    mapfile -t states < <(systemctl is-active "${units[@]}" 2>/dev/null || true)
    declare -A svc_map=()
    local idx key
    for idx in "${!units[@]}"; do
        key="${units[$idx]}"
        if [ "${states[$idx]:-inactive}" = "active" ]; then
            svc_map["$key"]=Online
        else
            svc_map["$key"]=Offline
        fi
    done
    if [ "${states[10]:-inactive}" != "active" ] \
       && [ ! -f /etc/systemd/system/cloudflared.service ] \
       && [ ! -f /lib/systemd/system/cloudflared.service ]; then
        svc_map[cloudflared]='No tunnel'
    fi

    if [[ ${LAYOUT:-classic} == compact ]] && (( UI_COLS >= 72 )); then
        compact_dashboard_body
        return 0
    fi

    section "HOST"
    facts "Provider" "${isp:-Unknown}" "OS" "${os:-Linux}" \
          "Uptime" "${up:-n/a}" "Time" "$now"
    section "RESOURCES"
    resource_meter "CPU" "${cpu:-n/a}"
    resource_meter "Memory" "${ram:-n/a}"
    resource_meter "Disk" "${disk:-n/a}"
    section "TRANSFER"
    facts "Today" "${bw_today:-n/a}" "Month" "${bw_month:-n/a}"
    [[ -z ${bw_src:-} ]] || paragraph "Source: $bw_src" "$DIM"
    section "ACCOUNTS"
    facts "Total" "${s_total:-0}" "Online" "${s_online:-0}" "SSH" "${s_ssh:-0}" \
          "VLESS" "${s_vless:-0}" "VMess" "${s_vmess:-0}" "Trojan" "${s_trojan:-0}" \
          "SSWS" "${s_ssws:-0}" "ZIVPN" "${s_zivpn:-0}"
    section "SERVICES"
    facts "Xray" "${svc_map[xray]}" "HAProxy" "${svc_map[haproxy]}" \
          "Dropbear" "${svc_map[dropbear]}" "sing-box" "${svc_map[sing-box]}" \
          "UDP Custom" "${svc_map[udp-custom]}" "ZIVPN" "${svc_map[zivpn]}" \
          "SSH WS" "${svc_map[ragnar-wsproxy]}" "WSS / SSL" "${svc_map[haproxy]}" \
          "SlowDNS" "${svc_map[slowdns]}" "BadVPN" "${svc_map[badvpn-udpgw]}" \
          "cloudflared" "${svc_map[cloudflared]}" "Web panel" "${svc_map[ragnar-web]}" \
          "DNS Router" "${svc_map[dnstm-dnsrouter]:-n/a}" "Slipstream" "${svc_map[dnstm-slip1]:-n/a}"
    ui_box_close
}

main_menu() {
    if [[ ${LAYOUT:-classic} == compact ]] && (( UI_COLS >= 72 )); then
        local lw=$(( (UI_COLS - 3) / 2 ))
        compact_menu_pair "$lw" "" "ACCOUNTS & ACCESS" "" "" "SERVICES & MONITORING" ""
        compact_menu_pair "$lw" "1" "SSH / SSL accounts" "" "5" "SlowDNS" ""
        compact_menu_pair "$lw" "2" "Xray accounts" "" "6" "Cloudflare" ""
        compact_menu_pair "$lw" "3" "UDP ZIVPN" "" "7" "Web panel" ""
        compact_menu_pair "$lw" "4" "UDP Custom" "" "8" "Status" ""
        compact_menu_pair "$lw" "" "" "" "9" "Tools" ""
        printf '\n'
        compact_menu_pair "$lw" "" "SYSTEM" "" "" "" ""
        compact_menu_pair "$lw" "10" "Update panel" "" "12" "Reboot VPS" "warn"
        compact_menu_pair "$lw" "11" "Clear RAM cache" "" "13" "Uninstall panel" "warn"
        compact_menu_pair "$lw" "t" "Appearance" "" "l" "Layout" ""
        compact_menu_pair "$lw" "x" "Exit" "dim" "" "@farisbazed · t.me/ragnaresim" "dim"
        return 0
    fi
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
    opt 14 "Slipstream" "QUIC-over-DNS tunnel (fast, Android)"
    section "SYSTEM"
    opt 10 "Update panel" "Back up state, then update from GitHub"
    opt 11 "Clear RAM cache" "Drop Linux filesystem caches"
    opt 12 "Reboot VPS" "Restart the whole server" warn
    opt 13 "Uninstall panel" "Restore snapshots and remove Ragnar" warn
    opt t "Appearance" "Theme and panel layout"
    opt l "Layout" "Choose a terminal design"
    opt x "Exit" "Leave this menu"
    paragraph "@farisbazed · https://t.me/ragnaresim" "$DIM"
}

# ---------------------------------------------------------------------
# SSH submenu
# ---------------------------------------------------------------------
ssh_create() {
    local u p d q i
    page_header "Create SSH account" "Set the login credentials and access limits."
    section "CREDENTIALS"
    read -rp "  Username: " u
    read -rsp "  Password (hidden): " p; echo
    section "LIMITS"
    read -rp "  Duration in days [30]: " d
    read -rp "  Quota in GB [0 = unlimited]: " q
    read -rp "  IP limit [0 = unlimited]: " i
    python3 "$CORE" ssh-add "$u" "$p" "${d:-30}" "${q:-0}" "${i:-0}"
    pause
}
ssh_list() { page_header "SSH accounts"; python3 "$CORE" ssh-list; pause; }
ssh_info() {
    local u
    page_header "SSH account details"
    read -rp "  Username: " u; python3 "$CORE" ssh-info "$u"; pause
}
ssh_edit() {
    local u what v
    page_header "Edit SSH account" "Choose a setting to update."
    read -rp "  Username to edit: " u
    kv "Account" "${u:-not set}"
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
    page_header "Delete SSH account" "This removes the account and its access to the host."
    read -rp "  Username to delete: " u
    read -rp "  Delete '${u:-<not set>}'? [y/N] " a
    case "$a" in y|Y) python3 "$CORE" ssh-del "$u" ;; *) echo "No changes made." ;; esac
    pause
}
ssh_menu() {
    while true; do
        page_header "SSH & SSL" "Shell accounts and access limits."
        section "SERVICES"
        facts "OpenSSH" "$(svc_dot ssh)" "Dropbear" "$(svc_dot dropbear)" "SSH-WS" "$(svc_dot ragnar-wsproxy)"
        section "ACCOUNT MANAGEMENT"
        opt 1 "Create account" "Username, password, expiry and limits"
        opt 2 "List accounts" "Show users, traffic used and quota"
        opt 3 "Edit / renew account" "Expiry, quota, IP limit, password or access"
        opt 4 "Delete account" "Remove a panel user" warn
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
    if python3 "$CORE" xray-add "${args[@]}" --no-links; then
        xray_link_browser "$u" route "Account created"
    else
        pause
    fi
}
xray_links() {
    local u; read -rp "Username: " u || return
    xray_link_browser "$u" route
}
xray_info() { local u; read -rp "Username: " u; python3 "$CORE" xray-info "$u"; pause; }
xray_copy_one() {
    local u; read -rp "Username: " u || return
    xray_link_browser "$u" protocol
}
xray_link_caption() {
    local title=${1%%' ('*} qualifier=${1#*' ('}
    printf '  %s\n' "${title//  / }"
    if [[ $title != "$1" ]]; then
        printf "  ${DIM}%s${N}\n" "${qualifier%')'}"
    fi
}
xray_link_browser() {
    local u=$1 first=$2 context=${3:-Account} catalog route proto item label group last
    local dimension=$first filter='' selected i count=0 answer
    local -a choices
    local -A seen
    if ! catalog=$(python3 "$CORE" xray-links "$u" --catalog); then
        printf '%s\n' "$catalog"; pause; return
    fi
    while IFS=$'\t' read -r route proto; do
        [[ -n $proto ]] && ((count+=1))
    done <<< "$catalog"
    if (( count == 0 )); then
        printf '  No connection links available.\n'; pause; return
    fi
    while true; do
        page_header "Connection links" "$context: $u"
        [[ -z $filter ]] || xray_link_caption "$filter"
        choices=(); seen=(); last=''
        while IFS=$'\t' read -r route proto; do
            [[ -n $proto ]] || continue
            if [[ $dimension == route ]]; then
                [[ -z $filter || $proto == "$filter" ]] || continue
                item=$route
                label=${route%%' ('*}; label=${label//  / }
                case "$route" in
                    *' (direct)') group=DIRECT ;;
                    *' (Cloudflare)') group=CLOUDFLARE ;;
                    *' (direct, SNI routed)') group='ANYTLS · DIRECT'; label="SNI routed · ${label##*port }" ;;
                    *' (direct fallback)') group='ANYTLS · DIRECT'; label="Fallback · ${label##*port }" ;;
                    *) group=ROUTES; label=$route ;;
                esac
            else
                [[ -z $filter || $route == "$filter" ]] || continue
                item=$proto; group=PROTOCOL
                case "$proto" in
                    VMESS) label=VMess ;; TROJAN) label=Trojan ;; ANYTLS) label=AnyTLS ;;
                    SSWS) label="Shadowsocks WS" ;; *) label=$proto ;;
                esac
            fi
            [[ ${seen[$item]:-} ]] && continue
            seen[$item]=1; choices+=("$item")
            [[ $last == "$group" ]] || section "$group"
            opt "${#choices[@]}" "$label"
            last=$group
        done <<< "$catalog"
        [[ $UI_BOX_OPEN == 1 ]] && ui_box_close
        printf '\n'
        [[ -n $filter ]] || opt A "Reveal all $count links"
        opt 0 "Back"
        if [[ -z $filter ]]; then menu_choice "Choose a $dimension:" || return
        else menu_choice "Reveal which $dimension?" || return; fi
        case "$MENU_CHOICE" in
            0)
                [[ -n $filter ]] || return 0
                filter=''; dimension=$first; continue ;;
            A|a)
                if [[ -z $filter ]]; then
                    read -rp "Print all private links? [y/N] " answer || return
                    case "$answer" in
                        y|Y) python3 "$CORE" xray-links "$u"; pause ;;
                    esac
                    continue
                fi ;;
        esac
        selected=''
        for i in "${!choices[@]}"; do
            [[ $MENU_CHOICE == "$((i+1))" ]] && selected=${choices[i]}
        done
        if [[ -z $selected ]]; then invalid_choice; continue; fi
        if [[ -z $filter ]]; then
            filter=$selected
            if [[ $dimension == route ]]; then dimension=protocol; else dimension=route; fi
            continue
        fi
        if [[ $dimension == route ]]; then route=$selected; proto=$filter
        else route=$filter; proto=$selected; fi
        page_header "Copy connection link" "$proto · $u"
        xray_link_caption "$route"
        section "PRIVATE LINK"
        python3 "$CORE" xray-links "$u" --one "$route" "$proto"
        printf '\n'
        pause
    done
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
        1) read -rp "Add how many days? " v; python3 "$CORE" xray-edit "$u" --days "$v" --extend --no-links ;;
        2) read -rp "New quota GB (0=inf): " v; python3 "$CORE" xray-edit "$u" --quota-gb "$v" --no-links ;;
        3) read -rp "New IP limit (0=inf): " v; python3 "$CORE" xray-edit "$u" --ip-limit "$v" --no-links ;;
        4) python3 "$CORE" xray-edit "$u" --enable --no-links ;;
        5) python3 "$CORE" xray-edit "$u" --disable --no-links ;;
        0) return ;;
        *) invalid_choice; return ;;
    esac
    pause
}
xray_del() {
    local u a
    page_header "Delete Xray account" "This removes the user from every enabled Xray protocol."
    read -rp "Username to delete: " u
    read -rp "Delete '${u:-<not set>}'? [y/N] " a
    case "$a" in y|Y) python3 "$CORE" xray-del "$u" ;; *) echo "No changes made." ;; esac
    pause
}
xray_menu() {
    while true; do
        local stats
        stats=$(python3 "$CORE" stats 2>/dev/null || echo '{}')
        page_header "Xray accounts" "One account serves all enabled protocols."
        section "PROTOCOL USERS"
        facts "VLESS" "$(stats_count vless "$stats")" "VMess" "$(stats_count vmess "$stats")" \
              "Trojan" "$(stats_count trojan "$stats")" "SSWS" "$(stats_count ssws "$stats")"
        section "SERVICES"
        facts "Xray" "$(svc_dot xray)" "sing-box / AnyTLS" "$(svc_dot sing-box)"
        section "ACCOUNT MANAGEMENT"
        opt 1 "Create account" "Enable all supported protocols at once"
        opt 2 "List accounts" "View traffic used, expiry, quota and status"
        opt 3 "Edit / renew account" "Expiry, quota, IP limit or access"
        opt 4 "Delete account" "Remove a user from all protocols" warn
        opt 5 "Account details" "Usage, limits and live traffic"
        section "SHARE & SERVICE"
        opt 6 "Browse links" "Choose a route first"
        opt 7 "Find by protocol" "Choose a protocol first"
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
    page_header "Edit ZIVPN account" "Update password, expiry or access."
    read -rp "  Username to edit: " u
    kv "Account" "${u:-not set}"
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
        page_header "UDP ZIVPN" "Password-based UDP access."
        section "CONNECTION"
        facts "Service" "$(svc_dot zivpn)" "Endpoint" "$(server_ip):5667/udp"
        section "ACCOUNTS"
        opt 1 "Create user" "Add a password and expiry"
        opt 2 "List users" "Review usernames and expiry dates"
        opt 3 "Edit / renew user" "Extend expiry, change password or toggle access"
        opt 4 "Delete user" "Remove one ZIVPN account" warn
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
        page_header "UDP Custom" "UDP forwarding with SSH account credentials."
        section "SERVICES"
        facts "UDP Custom" "$(svc_dot udp-custom)" "BadVPN" "$(svc_dot badvpn-udpgw)"
        section "ROUTING"
        kv "UDP range" "1–65535, except panel ports"
        kv "Forward to" "127.0.0.1:36712"
        kv "Gateway" "127.0.0.1:7300"
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
slowdns_build() {
    if [[ ! -x /usr/local/bin/dnstt-server ]]; then
        kv "Build" "Not installed · use 1 or 7" "$Y"
    elif [[ -f $1/.turbo_kcp_patched ]]; then
        kv "Build" "Turbo patch active" "$G"
    else
        kv "Build" "Standard · use 7 for Turbo"
    fi
}
slowdns_menu() {
    # SlowDNS is the other panel's implementation, integrated:
    # core/slowdns-setup.sh (their turbo build/NAT/CF/unit code),
    # config in settings.json, keys in $RAGNAR_DIR/slowdns/.
    local SD="$RAGNAR_DIR/slowdns"
    while true; do
        page_header "SlowDNS / DNSTT" "DNS tunnel settings and diagnostics."
        local sd_tsv ns pub mtu resolver target
        sd_tsv=$(python3 - "$RAGNAR_DIR/settings.json" <<'PY' 2>/dev/null
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    s = {}
print("\x1f".join(str(x) for x in [
    s.get("ns", ""),
    s.get("slowdns_pubkey", ""),
    s.get("slowdns_mtu", 1232),
    s.get("slowdns_resolver", ""),
    s.get("slowdns_target", 22),
]))
PY
)
        IFS=$'\x1f' read -r ns pub mtu resolver target <<<"$sd_tsv"
        mtu=${mtu:-1232}; target=${target:-22}
        section "TUNNEL PROFILE"
        kv "Nameserver" "${ns:-Not set}"
        case "$resolver" in
            '') kv "Resolver" "1.1.1.1:53 (default)" ;;
            *:*) kv "Resolver" "$resolver" ;;
            *) kv "Resolver" "$resolver:53" ;;
        esac
        kv "MTU" "$mtu"
        slowdns_build "$SD"
        kv "Public key" "${pub:-Not generated}"
        section "PACKET PATH"
        facts "Ingress" "UDP :53" "DNSTT" "127.0.0.1:5300" "SSH" "127.0.0.1:$target"
        paragraph "MTU 1232 is safest across resolvers." "$DIM"
        section "CONFIGURATION"
        opt 1 "Set nameserver & start" "Optional Cloudflare DNS records"
        opt 2 "Run diagnostics" "Check UDP listener and NS delegation"
        opt 3 "Change SSH backend" "OpenSSH :22 or Dropbear :109"
        opt 4 "Set resolver" "Choose the upstream DNS resolver"
        opt 5 "Set MTU" "1232 is the safest default"
        opt 6 "Replace server keys" "Generate a new key pair" warn
        opt 7 "Apply Turbo preset" "KCP patch, Dropbear, MTU 1232"
        section "SERVICE"
        opt 8 "Restart SlowDNS" "Restart with the current settings"
        opt 9 "Stop & disable SlowDNS" "Disable automatic startup" warn
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
               RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "$mtu" "" "$t"
               echo "Backend now 127.0.0.1:$t"; pause ;;
            4) read -rp "Resolver IP (e.g. 8.8.8.8, 1.1.1.1, or this server's IP): " v
               [ -n "$v" ] && RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "$mtu" "$v" "$target"
               pause ;;
            5) read -rp "MTU (1232 = default/safest, 512 = strict networks, 1400 = only if your path allows it): " v
               v=${v:-1232}
               RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "$v" "" "$target"
               pause ;;
            6) rm -f "$SD/server.key" "$SD/server.pub" /etc/vps-panel/slowdns/server.key /etc/vps-panel/slowdns/server.pub
               RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh"
               echo "New public key: $(cat "$SD/server.pub" 2>/dev/null)"
               pause ;;
            7) rm -f /usr/local/bin/dnstt-server "$SD/.turbo_kcp_patched" /etc/vps-panel/slowdns/.turbo_kcp_patched
               RAGNAR_DIR="$RAGNAR_DIR" bash "$RAGNAR_DIR/core/slowdns-setup.sh" "$ns" "" "1232" "" "109"
               echo "Turbo preset applied: rebuilt binary, Dropbear backend, MTU 1232"
               pause ;;
            8) systemctl restart slowdns; echo restarted; pause ;;
            9) systemctl stop slowdns; systemctl disable slowdns 2>/dev/null; echo stopped; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}
slipstream_menu() {
    # Slipstream (QUIC-over-DNS) through dnstm's port-53 router.
    # core/slipstream-setup.sh handles install/config; cannot run together
    # with the SlowDNS module (both need UDP 53).
    local SETUP="$RAGNAR_DIR/core/slipstream-setup.sh"
    [ -f "$SETUP" ] || SETUP="$DIR/core/slipstream-setup.sh"
    while true; do
        page_header "SLIPSTREAM (QUIC DNS)" "Fast DNS tunnel for Android clients (Hero DNSTT / SlipNet). Runs via dnstm."
        local dom router_state slip_state
        dom=$(dnstm tunnel list 2>/dev/null | awk '$1=="slip1"{print $5}')
        router_state=$(systemctl is-active dnstm-dnsrouter 2>/dev/null)
        slip_state=$(systemctl is-active dnstm-slip1 2>/dev/null)
        echo "Router   : ${router_state:-not installed} (UDP/TCP 53)"
        echo "Tunnel   : ${slip_state:-not installed} (slip1 -> SOCKS backend)"
        echo "Domain   : ${dom:-not set}"
        if systemctl is-active --quiet slowdns 2>/dev/null; then
            echo "WARNING  : SlowDNS is active and fights for port 53 - stop it (SlowDNS menu, option 9)"
        fi
        echo "DNS needs: A record ns.<domain> -> this server, NS record for the"
        echo "           tunnel subdomain -> ns.<domain> (Cloudflare: DNS only)."
        echo "iPhone   : iOS clients use plain DNSTT, not Slipstream (SlowDNS menu)."
        section "SETUP"
        opt 1 "Install / set up Slipstream" "dnstm router + slip1 tunnel"
        opt 2 "Set domain" "e.g. t.yourdomain.com, then start"
        opt 3 "Show client config" "Domain, certificate and dnst:// link"
        opt 4 "Diagnostics" "Router, listener and NS delegation"
        section "SERVICE"
        opt 5 "Restart tunnel" "Restart slip1"
        opt 6 "Stop tunnel" "Stop and disable slip1"
        opt 7 "Start tunnel" "Start and enable slip1"
        opt 0 "Back" "Return to the dashboard"
        menu_choice "Select an option:" || return
        c=$MENU_CHOICE
        case $c in
            1) bash "$SETUP" setup "${dom:-}"; pause ;;
            2) read -rp "Tunnel domain (e.g. t.yourdomain.com): " v
               [ -z "$v" ] && { echo "Domain cannot be empty"; pause; continue; }
               bash "$SETUP" setup "$v"; pause ;;
            3) bash "$SETUP" config; pause ;;
            4) bash "$SETUP" diagnose; pause ;;
            5) dnstm tunnel restart -t slip1 && echo restarted; pause ;;
            6) dnstm tunnel stop -t slip1 && echo stopped; pause ;;
            7) dnstm tunnel start -t slip1 && echo started; pause ;;
            0) return ;;
            *) invalid_choice ;;
        esac
    done
}
cloudflared_menu() {
    while true; do
        page_header "Cloudflare" "Domains, link hostnames and tunnels."
        section "ROUTING"
        facts "Tunnel" "$(svc_dot_cf)"
        paragraph "WebSocket protocols use ports 80 and 443. AnyTLS uses raw TLS and stays direct." "$DIM"
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
               cf_new=0
               [ -e /etc/systemd/system/cloudflared.service ] || cf_new=1
               cloudflared service install "$v" && systemctl enable --now cloudflared
               # Let uninstall remove the tunnel service this menu created,
               # even if the tunnel failed to start.
               if [ "$cf_new" = 1 ] && [ -e /etc/systemd/system/cloudflared.service ]; then
                   mkdir -p "${RAGNAR_STATE_DIR:-/var/lib/ragnar-panel}/installed" && \
                       : > "${RAGNAR_STATE_DIR:-/var/lib/ragnar-panel}/installed/cloudflared-service"
               fi
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
        page_header "Web panel" "Browser access and administrator settings."
        local dom url
        dom=$(python3 -c "import json;print(json.load(open('$RAGNAR_DIR/settings.json')).get('domain',''))" 2>/dev/null)
        [ -z "$dom" ] && dom=$(server_ip)
        url="https://$dom/panel"
        section "ACCESS"
        kv "URL" "$url"
        facts "Service" "$(svc_dot ragnar-web)"
        paragraph "Use the admin credentials set at install." "$DIM"
        section "ADMINISTRATION"
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
        page_header "Tools & diagnostics" "Maintenance and health checks for this VPS."
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
    page_header "Update panel" "Install the latest version from the main branch."
    section "BEFORE YOU UPDATE"
    paragraph "A backup is saved to /root first. Users, settings, certificates and SlowDNS keys are kept."
    ui_box_close
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
    page_header "Status & health" "Service state, bandwidth and listening ports."
    section "SYSTEM SERVICES"
    local -a units=(haproxy xray sing-box ragnar-wsproxy dropbear ssh zivpn udp-custom \
                    badvpn-udpgw slowdns cloudflared ragnar-web ragnar-check.timer ragnar-watchdog.timer)
    local -a states=()
    mapfile -t states < <(systemctl is-active "${units[@]}" 2>/dev/null || true)
    local i state
    local -a services=()
    for i in "${!units[@]}"; do
        state=Offline
        [[ ${states[i]:-inactive} == active ]] && state=Online
        services+=("${units[i]}" "$state")
    done
    facts "${services[@]}"
    section "BANDWIDTH"; bandwidth_lines
    section "LISTENING PORTS"
    ss -tulnp 2>/dev/null | grep -E ':(80|443|22|109|5667|36712|53|8446)\b' || true
    pause
}

# ---------------------------------------------------------------------
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

trap theme_reset_terminal EXIT
if [ "${RAGNAR_PREVIEW:-}" = "1" ]; then
    print_header; main_menu; exit 0
fi

while true; do
    print_header; main_menu
    ui_box_close
    read -rp "$(ui_prompt_prefix)Select menu: " opt || exit 0
    case $opt in
        1) ssh_menu ;;
        2) xray_menu ;;
        3) zivpn_menu ;;
        4) udpcustom_menu ;;
        5) slowdns_menu ;;
        14) slipstream_menu ;;
        6) cloudflared_menu ;;
        7) webpanel_menu ;;
        8) status_page ;;
        9) tools_menu ;;
        10) update_panel ;;
        11) sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; echo "RAM cleared"; pause ;;
        12) read -rp "Reboot the VPS now? [y/N] " a; [ "$a" = y ] && reboot ;;
        13) read -rp "UNINSTALL Ragnar Panel completely? [y/N] " a
            if [ "$a" = y ]; then
                bash "$RAGNAR_DIR/uninstall.sh"
                # The menu's own files are gone; do not keep drawing it.
                [ -d "$RAGNAR_DIR" ] || exit 0
            fi ;;
        t|T) theme_menu ;;
        l|L) layout_menu ;;
        x|X) theme_reset_terminal; clear_screen; echo "Bye - @farisbazed / https://t.me/ragnaresim"; exit 0 ;;
        *) invalid_choice ;;
    esac
done
