#!/bin/bash
# wallpaper-picker.sh — pick a wallpaper visually, in rofi.
#
# Step 1: which target (desktop / lock screen / login screen / all three),
#         or "Random wallpaper" — the per-target switches.
# Step 2: a grid of thumbnails from ~/.config/hypr/wallpapers/.
# Esc on the second step goes back to the first; Esc on the first exits.
#
# wallpaper.sh does the applying; this is only the interface.

set -uo pipefail

CORE="$HOME/.config/hypr/scripts/wallpaper.sh"
WALLPAPER_DIR="$HOME/.config/hypr/wallpapers"
THUMB_DIR="$HOME/.cache/wallpaper-thumbs"
THUMB_WIDTH=480
RASI="$HOME/.config/rofi/wallpaper.rasi"

mkdir -p "$THUMB_DIR"

mapfile -t IMAGES < <(
    find "$WALLPAPER_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        | sort
)

if (( ${#IMAGES[@]} == 0 )); then
    notify-send "Wallpaper" "No images in $WALLPAPER_DIR" 2>/dev/null
    exit 1
fi

# The thumbnail path is keyed by file and mtime, so a replaced image is never
# shown with its old preview.
thumb_path() {
    local img="$1" key
    key="$(printf '%s|%s' "$img" "$(stat -c %Y "$img" 2>/dev/null)" | sha1sum | cut -c1-16)"
    printf '%s/%s.jpg' "$THUMB_DIR" "$key"
}

# Build any missing previews up front: otherwise rofi decodes the 4K originals
# while drawing the grid, and the window stalls for seconds.
build_thumbs() {
    local missing=() img thumb
    for img in "${IMAGES[@]}"; do
        thumb="$(thumb_path "$img")"
        [[ -s "$thumb" ]] || missing+=("$img")
    done
    (( ${#missing[@]} == 0 )) && return 0
    (( ${#missing[@]} > 3 )) && \
        notify-send "Wallpaper" "Building ${#missing[@]} previews..." 2>/dev/null
    for img in "${missing[@]}"; do
        thumb="$(thumb_path "$img")"
        magick "$img" -auto-orient -thumbnail "${THUMB_WIDTH}x" -strip \
            -quality 85 "$thumb" 2>/dev/null || rm -f "$thumb"
    done
}

# The random-mode state: RANDOM_MODE[desktop] = on|off.
declare -A RANDOM_MODE=()
read_random() {
    local key value
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] && RANDOM_MODE["$key"]="$value"
    done < <("$CORE" random status)
}

is_random() { [[ "${RANDOM_MODE[$1]:-off}" == on ]]; }

# The name of the file currently on that target, or a dash. On a target in
# random mode the name says nothing — it changes at the next login anyway.
current_name() {
    local p
    is_random "$1" && { echo "󰒝  random"; return; }
    p="$("$CORE" current "$1")"
    [[ -n "$p" ]] && basename "$p" || echo "— not set —"
}

# The summary on the "Random wallpaper" row. Icons rather than words: three
# names do not fit on one row and get cut off with an ellipsis.
random_summary() {
    local t icons=()
    for t in desktop lock sddm; do
        is_random "$t" || continue
        case "$t" in
            desktop) icons+=("󰇄") ;;
            lock)    icons+=("󰌾") ;;
            sddm)    icons+=("󰍁") ;;
        esac
    done
    (( ${#icons[@]} )) && echo "on: ${icons[*]}" || echo "off"
}

choose_target() {
    local choice
    choice=$(printf '%s\n' \
        "󰇄  Desktop        $(current_name desktop)" \
        "󰌾  Lock screen    $(current_name lock)" \
        "󰍁  Login (SDDM)   $(current_name sddm)" \
        "󰆤  All three" \
        "󰒝  Random         $(random_summary)" \
        | rofi -dmenu -format i -p "Background" \
               -theme-str 'entry { placeholder: "What to change..."; } listview { lines: 5; }')
    case "$choice" in
        0) echo desktop ;;
        1) echo lock ;;
        2) echo sddm ;;
        3) echo all ;;
        4) echo random ;;
        *) return 1 ;;
    esac
}

# Step 2 for "Random": one switch per target. The menu stays open after a
# keypress — switching on more than one target at a time is the common case.
mark() { is_random "$1" && echo "󰄲  on" || echo "󰄱  off"; }

choose_random() {
    local row=0 choice
    while true; do
        read_random
        choice=$(printf '%s\n' \
            "󰇄  Desktop        $(mark desktop)" \
            "󰌾  Lock screen    $(mark lock)" \
            "󰍁  Login (SDDM)   $(mark sddm)" \
            "󰆤  All three" \
            | rofi -dmenu -format i -p "Random" -selected-row "$row" \
                   -mesg "Enter toggles, Esc goes back. A new image at every login; on the lock screen, at every lock." \
                   -theme-str 'entry { placeholder: "Where to turn it on..."; } listview { lines: 4; }') || return 0
        [[ "$choice" =~ ^[0-9]+$ ]] || return 0
        row="$choice"
        case "$choice" in
            0) "$CORE" random desktop toggle ;;
            1) "$CORE" random lock    toggle ;;
            2) "$CORE" random sddm    toggle ;;
            3) "$CORE" random all     toggle ;;
        esac
    done
}

# Rows for rofi: "label\0icon\x1fthumbnail-path".
# Written straight into the pipe: bash command substitution strips NUL bytes,
# and without the NUL rofi reads "icon<path>" as part of the label — no previews.
emit_rows() {
    local current="$1" img thumb marker
    for img in "${IMAGES[@]}"; do
        thumb="$(thumb_path "$img")"
        [[ -s "$thumb" ]] || thumb="$img"          # no preview built — show the original
        marker=""
        [[ "$img" == "$current" ]] && marker=" ●"   # the one currently set
        printf '%s%s\0icon\x1f%s\n' "$(basename "${img%.*}")" "$marker" "$thumb"
    done
}

choose_image() {
    local target="$1" label="$2" current idx mesg="Esc to go back"
    current="$("$CORE" current "$target")"

    # If the target is in random mode, picking an image switches it off — say so.
    local warn=0 t
    for t in desktop lock sddm; do
        [[ "$target" == "$t" || "$target" == all ]] || continue
        is_random "$t" && warn=1
    done
    (( warn )) && mesg="Esc to go back. Picking an image turns random mode off."

    idx=$(emit_rows "$current" \
        | rofi -dmenu -format i -show-icons -theme "$RASI" \
               -p "$label" -mesg "$mesg") || return 1
    [[ "$idx" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${IMAGES[$idx]}"
}

build_thumbs

while true; do
    read_random
    target="$(choose_target)" || exit 0
    case "$target" in
        desktop) label="Desktop" ;;
        lock)    label="Lock screen" ;;
        sddm)    label="Login screen" ;;
        all)     label="All three" ;;
        random)  choose_random; continue ;;
    esac

    if img="$(choose_image "$target" "$label")" && [[ -n "$img" ]]; then
        "$CORE" set "$target" "$img"
        exit $?
    fi
    # Esc on the grid goes back to picking a target
done
