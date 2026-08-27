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
#   shuffle [target...]                  a random image on a target, right now
#   random <target|all> [on|off|toggle]  random-wallpaper mode for a target
#   random status                        the mode's state (for the picker)
#   auto [target...]                     re-roll only the targets the mode is on for
#   restore                              restore the desktop wallpaper at login
#   pick                                 pick one visually in rofi (SUPER+SHIFT+W)
#   current <desktop|lock|sddm>          print the current path (for the picker)
#
# Image library: ~/.config/hypr/wallpapers/

set -uo pipefail

WALLPAPER_DIR="$HOME/.config/hypr/wallpapers"
STATE_DIR="$HOME/.local/state/hypr-wallpaper"
RANDOM_CONF="$STATE_DIR/random.conf"
SDDM_DIR="${WALLPAPER_SDDM_DIR:-/var/lib/sddm-wallpaper}"   # overridden in the tests
SDDM_IMG="$SDDM_DIR/current.jpg"
SDDM_SIZE="${WALLPAPER_SDDM_SIZE:-1920x1080}"   # the login screen's native resolution

TARGETS=(desktop lock sddm)

mkdir -p "$STATE_DIR"

notify() { notify-send "Wallpaper" "$1" 2>/dev/null; }
die() { notify "$1"; echo "wallpaper.sh: $1" >&2; exit 1; }

target_label() {
    case "$1" in
        desktop) echo "Desktop" ;;
        lock)    echo "Lock screen" ;;
        sddm)    echo "Login screen" ;;
        *)       echo "$1" ;;
    esac
}

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

# One way in for all three targets. Called inside a subshell wherever one
# failing target must not take the others down (auto, at login).
apply_to() {
    case "$1" in
        desktop) set_desktop "$2" ;;
        lock)    set_lock    "$2" ;;
        sddm)    set_sddm    "$2" ;;
        *)       die "unknown target: $1" ;;
    esac
}

# ---------- random-wallpaper mode ----------
#
# The state is three lines like "desktop=on" in $RANDOM_CONF. One file for all
# three targets, so switching one on leaves the other two alone.

random_enabled() {
    [[ -r "$RANDOM_CONF" ]] && grep -qx "$1=on" "$RANDOM_CONF"
}

random_set() {
    local target="$1" value="$2" t out=()
    for t in "${TARGETS[@]}"; do
        if [[ "$t" == "$target" ]]; then
            out+=("$t=$value")
        elif random_enabled "$t"; then
            out+=("$t=on")
        else
            out+=("$t=off")
        fi
    done
    printf '%s\n' "${out[@]}" > "$RANDOM_CONF"
}

random_status() {
    local t
    for t in "${TARGETS[@]}"; do
        random_enabled "$t" && echo "$t=on" || echo "$t=off"
    done
}

# A random image, preferably not the one already on that target: in a library
# of three files, true randomness regularly looks like nothing happened.
random_image() {
    local target="$1" cur img pool=() rest=()
    mapfile -t pool < <(list_images)
    (( ${#pool[@]} )) || return 1
    cur="$(current_path "$target")"
    if (( ${#pool[@]} > 1 )) && [[ -n "$cur" ]]; then
        for img in "${pool[@]}"; do
            [[ "$img" == "$cur" ]] || rest+=("$img")
        done
        (( ${#rest[@]} )) && pool=("${rest[@]}")
    fi
    printf '%s' "${pool[RANDOM % ${#pool[@]}]}"
}

# ---------- subcommands ----------

cmd_set() {
    local target="${1:-}" img="${2:-}"
    [[ -n "$target" && -n "$img" ]] || die "usage: wallpaper.sh set <desktop|lock|sddm|all> <file>"
    [[ -r "$img" ]] || die "no such file: $img"
    img="$(realpath "$img")"

    # Picking an image by hand means opting out of random mode on that target.
    local turned_off=0 t
    for t in "${TARGETS[@]}"; do
        [[ "$target" == "$t" || "$target" == all ]] || continue
        random_enabled "$t" && { random_set "$t" off; turned_off=1; }
    done
    local suffix=""
    (( turned_off )) && suffix=" (random mode off)"

    case "$target" in
        desktop) set_desktop "$img"; notify "Desktop: $(basename "$img")$suffix" ;;
        lock)    set_lock    "$img"; notify "Lock screen: $(basename "$img")$suffix" ;;
        sddm)    set_sddm    "$img"; notify "Login screen: $(basename "$img")$suffix" ;;
        all)
            set_desktop "$img"; set_lock "$img"; set_sddm "$img"
            notify "All three backgrounds: $(basename "$img")$suffix"
            ;;
        *) die "unknown target: $target" ;;
    esac
}

# Cycle through the library — the desktop only.
# With random mode on, the same key gives a random image instead: stepping to
# "the next one" would undo exactly what the mode promises.
cmd_next() {
    if random_enabled desktop; then
        cmd_shuffle desktop
        return
    fi

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

# A random image now, whatever the mode says. With no targets: the desktop.
cmd_shuffle() {
    local targets=("$@") t img applied=()
    (( ${#targets[@]} )) || targets=(desktop)
    for t in "${targets[@]}"; do
        img="$(random_image "$t")" || die "no images in $WALLPAPER_DIR"
        ( apply_to "$t" "$img" ) && applied+=("$(target_label "$t"): $(basename "$img")")
    done
    (( ${#applied[@]} )) && notify "$(printf '%s\n' "${applied[@]}")"
}

# Re-roll only the targets the mode is on for. Quiet: this runs from exec-once
# and from lock_cmd, where a notification would only be noise.
# Each target in a subshell: a failing magick must not take the others down.
cmd_auto() {
    local targets=("$@") t img
    (( ${#targets[@]} )) || targets=("${TARGETS[@]}")
    for t in "${targets[@]}"; do
        random_enabled "$t" || continue
        img="$(random_image "$t")" || continue
        ( apply_to "$t" "$img" ) || true
    done
}

cmd_random() {
    local target="${1:-}" action="${2:-toggle}" t new targets=() changed=()

    case "$target" in
        status)               random_status; return ;;
        desktop|lock|sddm)    targets=("$target") ;;
        all)                  targets=("${TARGETS[@]}") ;;
        *) die "usage: wallpaper.sh random <desktop|lock|sddm|all|status> [on|off|toggle]" ;;
    esac

    # "Toggle everything" is more predictable as "off, if anything is on".
    if [[ "$action" == toggle && "$target" == all ]]; then
        action=on
        for t in "${TARGETS[@]}"; do
            random_enabled "$t" && { action=off; break; }
        done
    fi

    for t in "${targets[@]}"; do
        case "$action" in
            on)     new=on ;;
            off)    new=off ;;
            toggle) random_enabled "$t" && new=off || new=on ;;
            *) die "usage: wallpaper.sh random <target> [on|off|toggle]" ;;
        esac
        random_set "$t" "$new"
        changed+=("$(target_label "$t") — $new")
    done

    # Switched on: show the result now, not at the next login.
    [[ "$action" == on ]] && cmd_auto "${targets[@]}"

    notify "Random wallpaper: $(printf '%s\n' "${changed[@]}")"
}

# Login: targets in random mode get a new image, the rest get the one they had
# (awww-daemon starts up empty and remembers nothing).
cmd_restore() {
    if random_enabled desktop; then
        cmd_auto desktop
    else
        local img
        img="$(current_path desktop)"
        [[ -n "$img" && -r "$img" ]] || img="$(list_images | head -1)"
        [[ -n "$img" ]] && ( set_desktop "$img" ) || true
    fi

    # Lock and login after the desktop: rebuilding the SDDM image takes about a
    # second, and must not hold up the one background that is visible at once.
    cmd_auto lock sddm
}

case "${1:-pick}" in
    set)     shift; cmd_set "$@" ;;
    next)    cmd_next ;;
    shuffle) shift; cmd_shuffle "$@" ;;
    random)  shift; cmd_random "$@" ;;
    auto)    shift; cmd_auto "$@" ;;
    restore) cmd_restore ;;
    current) current_path "${2:-desktop}" ;;
    pick)    exec "$HOME/.config/hypr/scripts/wallpaper-picker.sh" ;;
    *)       die "unknown command: $1" ;;
esac
