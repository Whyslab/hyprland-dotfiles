#!/usr/bin/env bash
# A screenshot that does not kill tooltips and menus.
#
# The usual "grim -g $(slurp)" runs slurp first, and slurp puts its own
# layer-shell surface over the whole screen. Hyprland sends wl_pointer.leave to
# the panel, GTK hides the tooltip — and grim captures an empty bar.
# Here the order is reversed: capture the pixels first, select the region after.
#
# Modes:
#   area   (default) — freeze the screen, draw a region, crop it out of the capture
#   screen           — the whole screen at once
#
# Assumption: one monitor, or several at the same scale. With mixed scales the
# coordinate conversion below stops being correct.

set -uo pipefail
export LC_ALL=C   # or awk prints "1920,0" instead of "1920.0" and the crop breaks

mode="${1:-area}"
dir="$HOME/Pictures/Screenshots"
mkdir -p "$dir"
file="$dir/$(date +'%F_%H-%M-%S').png"
tmp="$(mktemp -t screenshot-XXXXXX.png)"
picker=""

cleanup() {
    [ -n "$picker" ] && kill "$picker" 2>/dev/null
    rm -f "$tmp"
}
trap cleanup EXIT

# 1. Capture the screen first: nothing has appeared over it yet, so the
#    tooltip or menu is still there.
grim "$tmp" || exit 1

if [ "$mode" = screen ]; then
    cp "$tmp" "$file"
else
    # 2. Freeze the image so it is clear what is being selected.
    #    The capture does not come from here — hyprpicker is only a backdrop.
    if command -v hyprpicker >/dev/null 2>&1; then
        hyprpicker -r -z >/dev/null 2>&1 &
        picker=$!
        sleep 0.2
    fi

    # 3. The selection. Esc or right-click quietly cancels.
    geom="$(slurp)" || exit 0
    [ -z "$geom" ] && exit 0

    if [ -n "$picker" ]; then
        kill "$picker" 2>/dev/null
        picker=""
    fi

    # 4. slurp reports logical coordinates; grim's PNG is in physical pixels.
    scale="$(hyprctl monitors -j | jq -r '.[0].scale')"
    read -r imgw imgh < <(magick identify -format '%w %h' "$tmp")

    crop="$(awk -v g="$geom" -v s="$scale" -v iw="$imgw" -v ih="$imgh" '
        BEGIN {
            split(g, a, /[, x]+/)          # "X,Y WxH"
            x = int(a[1] * s); y = int(a[2] * s)
            w = int(a[3] * s + 0.999); h = int(a[4] * s + 0.999)
            if (x < 0) x = 0; if (y < 0) y = 0
            if (x + w > iw) w = iw - x
            if (y + h > ih) h = ih - y
            if (w <= 0 || h <= 0) exit 1
            printf "%dx%d+%d+%d", w, h, x, y
        }')" || exit 1

    magick "$tmp" -crop "$crop" +repage "$file" || exit 1
fi

wl-copy < "$file"
notify-send "Screenshot" "$file"
