#!/bin/bash
# wallpaper.sh — three independent backgrounds, driven from one place.
#
#   desktop      → awww (a Wayland wallpaper daemon)
#   lock screen  → hyprlock reads the $STATE_DIR/lock.img symlink
#   login screen → SDDM reads /var/lib/sddm-wallpaper/current.jpg
#
# Subcommands:
#   set <desktop|lock|sddm|all> <file>   set one specific image
#   next                                 next desktop wallpaper (SUPER+W)
#   restore                              restore the desktop wallpaper at login
#   pick                                 pick one visually in rofi (SUPER+SHIFT+W)
#   current <desktop|lock|sddm>          print the current path (for the picker)
#
# Image library: ~/.config/hypr/wallpapers/

set -uo pipefail

WALLPAPER_DIR="$HOME/.config/hypr/wallpapers"
STATE_DIR="$HOME/.local/state/hypr-wallpaper"
SDDM_DIR="/var/lib/sddm-wallpaper"
SDDM_IMG="$SDDM_DIR/current.jpg"
SDDM_SIZE="${WALLPAPER_SDDM_SIZE:-1920x1080}"   # the login screen's native resolution

mkdir -p "$STATE_DIR"

notify() { notify-send "Wallpaper" "$1" 2>/dev/null; }
die() { notify "$1"; echo "wallpaper.sh: $1" >&2; exit 1; }

# The awww daemon may not have come up when Hyprland started.
ensure_daemon() {
    pgrep -x awww-daemon >/dev/null 2>&1 && return 0
    nohup awww-daemon >/dev/null 2>&1 &
    for _ in $(seq 1 40); do          # wait up to 4s rather than sleeping blindly
        sleep 0.1
        awww query >/dev/null 2>&1 && return 0
    done
    return 1
}

# Every image in the library, in a stable (sorted) order.
list_images() {
    find "$WALLPAPER_DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        | sort
}

current_path() {
    local f="$STATE_DIR/$1.path"
    [[ -r "$f" ]] && cat "$f" || true
}

# ---------- applying to each target ----------

set_desktop() {
    local img="$1"
    ensure_daemon || die "awww-daemon did not start"
    awww img "$img" \
        --transition-fps 60 \
        --transition-type grow \
        --transition-pos 0.5,0.5 \
        --transition-duration 1.2 || die "awww could not set $(basename "$img")"
    echo "$img" > "$STATE_DIR/desktop.path"
}

set_lock() {
    local img="$1"
    ln -sfn "$img" "$STATE_DIR/lock.img"
    echo "$img" > "$STATE_DIR/lock.path"
}

set_sddm() {
    local img="$1"
    if [[ ! -d "$SDDM_DIR" ]]; then
        die "$SDDM_DIR does not exist — create it once: sudo install -d -o $USER -g $USER -m 755 $SDDM_DIR"
    fi
    if [[ ! -w "$SDDM_DIR" ]]; then
        die "$SDDM_DIR is not writable — check its owner"
    fi
    # Scale it down to the screen: the greeter has no reason to decode 4K, and
    # a JPEG under a fixed name saves the theme from guessing the extension.
    local tmp="$SDDM_DIR/.current.tmp.jpg"
    magick "$img" -resize "${SDDM_SIZE}^" -gravity center -extent "$SDDM_SIZE" \
        -strip -quality 90 "$tmp" || { rm -f "$tmp"; die "magick could not process $(basename "$img")"; }
    chmod 644 "$tmp"
    mv -f "$tmp" "$SDDM_IMG"   # atomic: the greeter never sees a half-written file
    echo "$img" > "$STATE_DIR/sddm.path"
}

# ---------- subcommands ----------

cmd_set() {
    local target="${1:-}" img="${2:-}"
    [[ -n "$target" && -n "$img" ]] || die "usage: wallpaper.sh set <desktop|lock|sddm|all> <file>"
    [[ -r "$img" ]] || die "no such file: $img"
    img="$(realpath "$img")"

    case "$target" in
        desktop) set_desktop "$img"; notify "Desktop: $(basename "$img")" ;;
        lock)    set_lock    "$img"; notify "Lock screen: $(basename "$img")" ;;
        sddm)    set_sddm    "$img"; notify "Login screen: $(basename "$img")" ;;
        all)
            set_desktop "$img"; set_lock "$img"; set_sddm "$img"
            notify "All three backgrounds: $(basename "$img")"
            ;;
        *) die "unknown target: $target" ;;
    esac
}

# Cycle through the library — the desktop only.
cmd_next() {
    local state_file="$STATE_DIR/index"
    mapfile -t images < <(list_images)
    (( ${#images[@]} )) || die "no images in $WALLPAPER_DIR"

    local cur=0
    [[ -r "$state_file" ]] && cur="$(cat "$state_file")"
    [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
    (( cur >= ${#images[@]} )) && cur=0

    echo $(( (cur + 1) % ${#images[@]} )) > "$state_file"

    set_desktop "${images[$cur]}"
    notify "$(basename "${images[$cur]}")"
}

# Restore the desktop wallpaper after login: awww-daemon starts up empty.
cmd_restore() {
    local img
    img="$(current_path desktop)"
    [[ -n "$img" && -r "$img" ]] || img="$(list_images | head -1)"
    [[ -n "$img" ]] || exit 0
    ensure_daemon || exit 1
    set_desktop "$img"
}

case "${1:-pick}" in
    set)     shift; cmd_set "$@" ;;
    next)    cmd_next ;;
    restore) cmd_restore ;;
    current) current_path "${2:-desktop}" ;;
    pick)    exec "$HOME/.config/hypr/scripts/wallpaper-picker.sh" ;;
    *)       die "unknown command: $1" ;;
esac
