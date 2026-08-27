#!/usr/bin/env bash
# install.sh — install these dotfiles, in whole or in part.
#
#   ./install.sh                          pick modules interactively
#   ./install.sh --all                    every module
#   ./install.sh --modules core,menus     just those
#   ./install.sh --list                   what the modules are
#   ./install.sh --dry-run                print every step, change nothing
#   ./install.sh --prefix /tmp/test       install into a sandbox
#
# Nothing needs root, and nothing is overwritten without a copy: every file
# this replaces is saved under ~/.local/share/hyprland-dotfiles/backup-<date>/,
# and uninstall.sh puts it back from there.

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
say()  { printf '%b\n' "${BLUE}==>${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}  ok${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}  !!${NC} $*"; }
die()  { printf '%b\n' "${RED}error:${NC} $*" >&2; exit 1; }

SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# ---------------------------------------------------------------- modules

# name|dependencies|one-line description
MODULES=(
  "core|hyprland|The compositor itself: keybindings, window rules, the look"
  "panel|hyprpanel|The status bar, with CPU/RAM/disk modules that show what is actually heavy"
  "terminal|kitty btop|Terminal and system monitor, matching the palette"
  "menus|rofi wlogout|The rofi palette and the power menu"
  "scripts|grim slurp|Screenshots, the wallpaper switcher, the btop scratchpad"
  "fonts||Font rules: colour emoji ahead of icon fonts, correct Han glyphs"
  "housekeeping||A weekly timer that clears regenerable caches"
  "wallpapers||An empty wallpaper directory plus a wallhaven fetcher"
)

module_names() { printf '%s\n' "${MODULES[@]}" | cut -d'|' -f1; }
module_field() { printf '%s\n' "${MODULES[@]}" | awk -F'|' -v m="$1" -v f="$2" '$1==m {print $f}'; }

# Other repositories in the same series. Optional, cloned only if asked for.
COMPANIONS=(
  "hypr-lock-theme|The lock screen: hyprlock + hypridle, generated 4K wallpapers"
  "screen-sleep|A settings window for idle, sleep and the night filter"
  "rofi-launcher|The application launcher bound to SUPER+R"
  "rofi-command-center|200 system commands in a searchable palette"
  "backup-manager|Encrypted nightly backups on borg"
)

# ---------------------------------------------------------------- arguments

DRY=0; PREFIX=""; ALL=0; CHOSEN=""; LIST=0; WITH_COMPANIONS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)        ALL=1; shift ;;
        --modules)    CHOSEN="$2"; shift 2 ;;
        --companions) WITH_COMPANIONS="$2"; shift 2 ;;
        --list)       LIST=1; shift ;;
        --dry-run)    DRY=1; shift ;;
        --prefix)     PREFIX="${2%/}"; shift 2 ;;
        -h|--help)    sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

[[ $EUID -ne 0 ]] || die "do not run this as root — it installs into your home directory"

if (( LIST )); then
    printf '%b\n' "${BOLD}Modules${NC}"
    for m in $(module_names); do
        printf '  %b%-13s%b %s\n' "$GREEN" "$m" "$NC" "$(module_field "$m" 3)"
        deps=$(module_field "$m" 2)
        [[ -n "$deps" ]] && printf '                %bneeds: %s%b\n' "$DIM" "$deps" "$NC"
    done
    echo
    printf '%b\n' "${BOLD}Companion repositories${NC} (cloned on request, each installs itself)"
    for c in "${COMPANIONS[@]}"; do
        printf '  %b%-21s%b %s\n' "$GREEN" "${c%%|*}" "$NC" "${c#*|}"
    done
    exit 0
fi

CONFIG_HOME="${PREFIX}${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${PREFIX}${XDG_DATA_HOME:-$HOME/.local/share}"
UNIT_DIR="${CONFIG_HOME}/systemd/user"
BIN_DIR="${PREFIX}${HOME}/.local/bin"
STATE="${DATA_HOME}/hyprland-dotfiles"
BACKUP="${STATE}/backup-$(date +%Y%m%d_%H%M%S)"
MANIFEST="${STATE}/installed.txt"

run() { if (( DRY )); then printf '   would run: %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- selection

selected=()
if (( ALL )); then
    mapfile -t selected < <(module_names)
elif [[ -n "$CHOSEN" ]]; then
    IFS=',' read -ra selected <<<"$CHOSEN"
    for m in "${selected[@]}"; do
        module_field "$m" 1 | grep -q . || die "no such module: $m (try --list)"
    done
else
    [[ -t 0 ]] || die "not a terminal — use --all or --modules (see --list)"
    printf '%b\n' "${BOLD}Which modules do you want?${NC}"
    echo
    for m in $(module_names); do
        printf '  %b%-13s%b %s\n' "$GREEN" "$m" "$NC" "$(module_field "$m" 3)"
    done
    echo
    read -rp "Modules, comma-separated, or Enter for all: " answer
    if [[ -z "${answer// }" ]]; then
        mapfile -t selected < <(module_names)
    else
        IFS=',' read -ra selected <<<"${answer// }"
        for m in "${selected[@]}"; do
            module_field "$m" 1 | grep -q . || die "no such module: $m"
        done
    fi
fi

say "Installing: ${selected[*]}"
say "Into: ${PREFIX:-$HOME}"
(( DRY )) && warn "dry run — nothing will be written"

# ---------------------------------------------------------------- dependencies

if [[ -z "$PREFIX" ]]; then
    missing=()
    for m in "${selected[@]}"; do
        for dep in $(module_field "$m" 2); do
            command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
        done
    done
    if (( ${#missing[@]} )); then
        warn "not installed: $(printf '%s ' "${missing[@]}" | sort -u | tr '\n' ' ')"
        warn "the configs are copied anyway; install them when you need them"
    else
        ok "every dependency of the chosen modules is present"
    fi
fi

# ---------------------------------------------------------------- helpers

record() { (( DRY )) || { mkdir -p "$(dirname "$MANIFEST")"; printf '%s\n' "$1" >> "$MANIFEST"; }; }

# Copy a file into place, saving whatever was there first.
place() {
    local src="$1" dst="$2"
    if [[ -e "$dst" || -L "$dst" ]]; then
        if (( DRY )); then
            printf '   would back up: %s\n' "$dst"
        else
            local rel="${dst#"${PREFIX}"}"
            mkdir -p "${BACKUP}$(dirname "$rel")"
            cp -a "$dst" "${BACKUP}${rel}"
        fi
    fi
    run install -Dm644 "$src" "$dst"
    record "$dst"
}

place_exec() {
    local src="$1" dst="$2"
    if [[ -e "$dst" ]]; then
        if (( DRY )); then printf '   would back up: %s\n' "$dst"
        else
            local rel="${dst#"${PREFIX}"}"
            mkdir -p "${BACKUP}$(dirname "$rel")"
            cp -a "$dst" "${BACKUP}${rel}"
        fi
    fi
    run install -Dm755 "$src" "$dst"
    record "$dst"
}

# Substitute __HOME__ before writing, so no config carries an absolute path
# belonging to whoever assembled the repository.
place_templated() {
    local src="$1" dst="$2"
    if (( DRY )); then
        printf '   would write: %s (with __HOME__ -> %s)\n' "$dst" "$HOME"
        return 0
    fi
    if [[ -e "$dst" ]]; then
        local rel="${dst#"${PREFIX}"}"
        mkdir -p "${BACKUP}$(dirname "$rel")"
        cp -a "$dst" "${BACKUP}${rel}"
    fi
    mkdir -p "$(dirname "$dst")"
    sed "s|__HOME__|${HOME}|g" "$src" > "$dst"
    chmod 644 "$dst"
    record "$dst"
}

has() { printf '%s\n' "${selected[@]}" | grep -qx "$1"; }

# ---------------------------------------------------------------- modules

if has core; then
    say "core"
    place_templated "${SRC}/config/hypr/hyprland.conf" "${CONFIG_HOME}/hypr/hyprland.conf"
    place            "${SRC}/config/hypr/colors.conf"  "${CONFIG_HOME}/hypr/colors.conf"
    ok "hyprland.conf and the palette"
fi

if has panel; then
    say "panel"
    for f in config.json modules.json modules.scss; do
        place_templated "${SRC}/config/hyprpanel/${f}" "${CONFIG_HOME}/hyprpanel/${f}"
    done
    for f in hyprpanel-cpu.sh hyprpanel-ram.sh hyprpanel-storage.sh; do
        place_exec "${SRC}/scripts/${f}" "${CONFIG_HOME}/hypr/scripts/${f}"
    done
    ok "the bar, with its CPU/RAM/disk modules"
fi

if has terminal; then
    say "terminal"
    place "${SRC}/config/kitty/kitty.conf" "${CONFIG_HOME}/kitty/kitty.conf"
    place "${SRC}/config/btop/btop.conf"   "${CONFIG_HOME}/btop/btop.conf"
    if [[ -d "${SRC}/config/btop/themes" ]]; then
        for t in "${SRC}"/config/btop/themes/*; do
            [[ -f "$t" ]] && place "$t" "${CONFIG_HOME}/btop/themes/$(basename "$t")"
        done
    fi
    place_templated "${SRC}/scripts/btop-scratch.kitty.conf" "${CONFIG_HOME}/hypr/scripts/btop-scratch.kitty.conf"
    ok "kitty and btop"
fi

if has menus; then
    say "menus"
    place "${SRC}/config/rofi/config.rasi"    "${CONFIG_HOME}/rofi/config.rasi"
    place "${SRC}/config/rofi/wallpaper.rasi" "${CONFIG_HOME}/rofi/wallpaper.rasi"
    place_templated "${SRC}/config/wlogout/layout" "${CONFIG_HOME}/wlogout/layout"
    place_templated "${SRC}/config/wlogout/style.css" "${CONFIG_HOME}/wlogout/style.css"
    for icon in "${SRC}"/config/wlogout/icons/*; do
        [[ -f "$icon" ]] && place "$icon" "${CONFIG_HOME}/wlogout/icons/$(basename "$icon")"
    done
    ok "the rofi palette and the power menu"
fi

if has scripts; then
    say "scripts"
    for f in screenshot.sh sysmon.sh wallpaper.sh wallpaper-picker.sh dismiss-startup-notify.sh; do
        place_exec "${SRC}/scripts/${f}" "${CONFIG_HOME}/hypr/scripts/${f}"
    done
    ok "screenshots, wallpaper switching, the btop scratchpad"
fi

if has fonts; then
    say "fonts"
    place "${SRC}/config/fontconfig/fonts.conf" "${CONFIG_HOME}/fontconfig/fonts.conf"
    ok "emoji ahead of icon fonts, and correct Han glyphs"
fi

if has housekeeping; then
    say "housekeeping"
    place_exec "${SRC}/scripts/clean-caches.sh" "${BIN_DIR}/clean-caches.sh"
    place "${SRC}/systemd/clean-caches.service" "${UNIT_DIR}/clean-caches.service"
    place "${SRC}/systemd/clean-caches.timer"   "${UNIT_DIR}/clean-caches.timer"
    if [[ -z "$PREFIX" ]]; then
        run systemctl --user daemon-reload
        run systemctl --user enable --now clean-caches.timer
    fi
    ok "a weekly cache cleanup timer"
fi

if has wallpapers; then
    say "wallpapers"
    run install -d -m 755 "${CONFIG_HOME}/hypr/wallpapers"
    # The note goes into the manifest so uninstall removes it again; the
    # directory itself, and any images in it, are left alone either way.
    if [[ ! -e "${CONFIG_HOME}/hypr/wallpapers/README.md" ]]; then
        place "${SRC}/wallpapers/README.md" "${CONFIG_HOME}/hypr/wallpapers/README.md"
    fi
    ok "empty wallpaper directory at ${CONFIG_HOME}/hypr/wallpapers"
    warn "no images are shipped — see wallpapers/README.md for where to get some"
fi

# ---------------------------------------------------------------- companions

if [[ -n "$WITH_COMPANIONS" && -z "$PREFIX" ]]; then
    say "Companion repositories"
    IFS=',' read -ra wanted <<<"${WITH_COMPANIONS// }"
    for repo in "${wanted[@]}"; do
        printf '%s\n' "${COMPANIONS[@]}" | grep -q "^${repo}|" \
            || { warn "unknown companion: ${repo}"; continue; }
        target="${HOME}/Projects/${repo}"
        if [[ -d "$target" ]]; then
            warn "${target} already exists, leaving it alone"
            continue
        fi
        run git clone --depth 1 "https://github.com/Whyslab/${repo}.git" "$target"
        ok "cloned ${repo} — run its own install.sh when you are ready"
    done
fi

# ---------------------------------------------------------------- done

echo
if (( DRY )); then
    ok "Dry run finished."
    exit 0
fi
if [[ -n "$PREFIX" ]]; then
    ok "Sandbox install finished: ${PREFIX}"
    exit 0
fi

ok "Installation finished."
[[ -d "$BACKUP" ]] && echo "   Replaced files were saved to: ${BACKUP}"
echo
echo "  Apply the compositor config:  hyprctl reload"
echo "  See what was installed:       cat ${MANIFEST}"
echo "  Undo all of it:               ./uninstall.sh"
echo
if has core; then
    warn "hyprland.conf refers to companion tools that are not installed by this"
    warn "repository — the launcher on SUPER+R, the command palette on SUPER+SHIFT+C,"
    warn "the backup menu on SUPER+SHIFT+B. Those keys do nothing until you install"
    warn "them (./install.sh --companions rofi-launcher,...) or remove the lines."
fi
