#!/bin/bash
# Presentation only: never source the user's saved preference.
THEMES=(default orchid evergreen cobalt parchment)
THEME_HINTS=("Terminal colors" "Plum and lilac" "Pine and sage" "Midnight and blue" "Warm paper and ink")
LAYOUTS=(classic boxed compact ledger)
LAYOUT_HINTS=("Original hairline view" "Rounded card panels" "Two-column split HUD" "Double-ruled console")
LAYOUT=classic
LAYOUT_FILE=''
UI_BOX_OPEN=0

# Each role has an RGB hex value, an xterm palette index and a basic ANSI index.
theme_color() {
    local var=$1 plane=$2 hex index basic
    IFS=/ read -r hex index basic <<<"$3"
    case $COLOR_MODE in
        rgb) printf -v "$var" '\e[%d;2;%d;%d;%dm' "$plane" \
                 "$((16#${hex:0:2}))" "$((16#${hex:2:2}))" "$((16#${hex:4:2}))" ;;
        indexed) printf -v "$var" '\e[%d;5;%dm' "$plane" "$index" ;;
        ansi) printf -v "$var" '\e[%dm' "$(( (plane == 48 ? 40 : 30) + basic ))" ;;
    esac
}

theme_apply() {
    local paper ink accent muted ok warn bad
    case "$1" in
        orchid)
            paper=1b1022/234/0; ink=f6eafa/255/7; accent=d7a6ef/183/5; muted=bca9c8/182/7 ;;
        evergreen)
            paper=0d1c17/234/0; ink=e5f3e8/255/7; accent=a6d6ab/151/2; muted=9fb7ad/109/7 ;;
        cobalt)
            paper=0b1730/17/0; ink=ecf3ff/255/7; accent=73a9ff/111/6; muted=a8bad4/146/7 ;;
        parchment)
            paper=e8dcc3/187/7; ink=30281f/235/0; accent=65402e/94/0; muted=655846/240/0 ;;
        *) set -- default ;;
    esac
    THEME=$1
    C=''; B=''; DIM=''; G=''; Y=''; R=''; N=''; BADGE=''; CANVAS=''
    [[ $COLOR_MODE != none ]] || return 0
    B=$'\e[1m'; N=$'\e[0m'
    if [[ $THEME == default ]]; then
        C=$'\e[36m'; DIM=$'\e[90m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; BADGE=$'\e[7;36m'
        return 0
    fi
    if [[ $THEME == parchment ]]; then
        ok=28553c/22/2; warn=774308/94/1; bad=8a2933/88/1
    else
        ok=9cdbb0/151/2; warn=f3c582/222/3; bad=ff9b9c/210/1
    fi
    local bg fg
    theme_color bg 48 "$paper"; theme_color fg 38 "$ink"
    theme_color C 38 "$accent"; theme_color DIM 38 "$muted"
    theme_color G 38 "$ok"; theme_color Y 38 "$warn"; theme_color R 38 "$bad"
    CANVAS="$N$bg$fg"; N=$CANVAS
    BADGE="$C"$'\e[7m'
}

layout_apply() {
    case "$1" in
        classic|boxed|compact|ledger) LAYOUT=$1 ;;
        *) LAYOUT=classic ;;
    esac
}

layout_load() {
    local saved='' config=${XDG_CONFIG_HOME:-}
    LAYOUT_FILE=''
    if [[ $config != /* && ${HOME:-} == /* ]]; then config=$HOME/.config; fi
    if [[ $config == /* ]]; then
        LAYOUT_FILE=$config/ragnar/terminal-layout
        if [[ -f $LAYOUT_FILE && -r $LAYOUT_FILE ]]; then IFS= read -r saved < "$LAYOUT_FILE" || :; fi
    fi
    layout_apply "$saved"
}

layout_save() {
    local tmp
    [[ -n $LAYOUT_FILE ]] || return 1
    mkdir -p -- "${LAYOUT_FILE%/*}" && tmp=$(mktemp -- "${LAYOUT_FILE}.XXXXXX") || return 1
    if printf '%s\n' "$1" > "$tmp" && mv -fT -- "$tmp" "$LAYOUT_FILE"; then return 0; fi
    rm -f -- "$tmp"
    return 1
}

theme_load() {
    local saved='' colors config=${XDG_CONFIG_HOME:-}
    THEME_FILE=''; COLOR_MODE=none
    if [[ $config != /* && ${HOME:-} == /* ]]; then config=$HOME/.config; fi
    if [[ $config == /* ]]; then
        THEME_FILE=$config/ragnar/terminal-theme
        if [[ -f $THEME_FILE && -r $THEME_FILE ]]; then IFS= read -r saved < "$THEME_FILE" || :; fi
    fi
    if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
        case "${COLORTERM:-}:$TERM" in
            truecolor:*|24bit:*|*:*-direct) COLOR_MODE=rgb ;;
            *) colors=$(tput colors 2>/dev/null) || colors=0
               if [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 256 )); then COLOR_MODE=indexed
               elif [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then COLOR_MODE=ansi; fi ;;
        esac
    fi
    theme_apply "$saved"
    layout_load
}

theme_save() {
    local tmp
    [[ -n $THEME_FILE ]] || return 1
    mkdir -p -- "${THEME_FILE%/*}" && tmp=$(mktemp -- "${THEME_FILE}.XXXXXX") || return 1
    if printf '%s\n' "$1" > "$tmp" && mv -fT -- "$tmp" "$THEME_FILE"; then return 0; fi
    rm -f -- "$tmp"
    return 1
}

theme_reset_terminal() { [[ -z $CANVAS ]] || printf '\e[0m'; }

theme_option() (
    local outer=$N outer_dim=$DIM active=$THEME key=$1 slug=$2 hint=$3 label=${2^}
    local inner vis pad
    theme_apply "$slug"
    [[ $slug != "$active" ]] || label+=' [current]'
    if [[ $LAYOUT == boxed && ${UI_BOX_OPEN:-0} == 1 ]]; then
        inner=$((UI_COLS - 4))
        printf '%s│%s %s%s %s %s  %s' "$outer_dim" "$outer" "$N" "$BADGE" "$key" "$outer" "$label"
        vis=$((5 + ${#label}))
        if (( UI_COLS >= 58 && 27 + ${#hint} <= inner )); then
            printf '%*s%s%s%s' "$((22 - ${#label}))" '' "$outer_dim" "$hint" "$outer"
            vis=$((27 + ${#hint}))
        fi
        pad=$((inner - vis))
        (( pad > 0 )) && printf '%*s' "$pad" ''
        printf ' %s│%s\n' "$outer_dim" "$outer"
        return 0
    fi
    printf '  %s%s %s %s  %s' "$N" "$BADGE" "$key" "$outer" "$label"
    if (( UI_COLS >= 50 )); then printf '%*s%s' "$((22 - ${#label}))" '' "$hint"; fi
    printf '\n'
)

layout_option() {
    local key=$1 slug=$2 hint=$3 label=${2^}
    [[ $slug != "$LAYOUT" ]] || label+=' [current]'
    opt "$key" "$label" "$hint"
}

layout_menu() {
    local i selected message=''
    while true; do
        page_header "Panel layout" "Choose a terminal panel design."
        section "DESIGNS"
        for i in "${!LAYOUTS[@]}"; do
            layout_option "$((i + 1))" "${LAYOUTS[i]}" "${LAYOUT_HINTS[i]}"
        done
        opt 0 "Back" "Return to the dashboard"
        [[ -z $message ]] || paragraph "$message" "$Y"
        menu_choice "Select a layout:" || return
        case "$MENU_CHOICE" in
            0) return ;;
            [1-4]) selected=${LAYOUTS[MENU_CHOICE-1]} ;;
            *) invalid_choice; continue ;;
        esac
        message=''
        layout_save "$selected" 2>/dev/null || message="Applied for this session only. Could not save preference."
        layout_apply "$selected"
    done
}

theme_menu() {
    local i selected message=''
    while true; do
        page_header "Appearance" "Choose a terminal theme and layout."
        section "COLOR PALETTES"
        for i in "${!THEMES[@]}"; do
            theme_option "$((i + 1))" "${THEMES[i]}" "${THEME_HINTS[i]}"
        done
        section "PANEL LAYOUTS"
        for i in "${!LAYOUTS[@]}"; do
            layout_option "$((i + 6))" "${LAYOUTS[i]}" "${LAYOUT_HINTS[i]}"
        done
        opt 0 "Back" "Return to the dashboard"
        [[ $COLOR_MODE != none ]] || paragraph "Color is off for this terminal." "$DIM"
        [[ -z $message ]] || paragraph "$message" "$Y"
        menu_choice "Select a theme or layout:" || return
        case "$MENU_CHOICE" in
            0) return ;;
            [1-5])
                selected=${THEMES[MENU_CHOICE-1]}
                message=''
                theme_save "$selected" 2>/dev/null || message="Applied for this session only. Could not save preference."
                theme_reset_terminal
                theme_apply "$selected" ;;
            [6-9])
                selected=${LAYOUTS[MENU_CHOICE-6]}
                message=''
                layout_save "$selected" 2>/dev/null || message="Applied for this session only. Could not save preference."
                layout_apply "$selected" ;;
            *) invalid_choice; continue ;;
        esac
    done
}
