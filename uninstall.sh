#!/usr/bin/env bash
# uninstall.sh — remove what install.sh put in place.
#
#   ./uninstall.sh                    remove the installed files, restore backups
#   ./uninstall.sh --keep-backups     do not restore, just remove
#   ./uninstall.sh --dry-run          print what would happen
#   ./uninstall.sh --prefix /tmp/test undo a sandbox install
#
# It works from the manifest install.sh wrote, so it removes exactly what was
# installed and nothing else. Files that were replaced are put back from the
# most recent backup directory.

set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
say()  { printf '%b\n' "${BLUE}==>${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}  ok${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}  !!${NC} $*"; }
die()  { printf '%b\n' "${RED}error:${NC} $*" >&2; exit 1; }

DRY=0; PREFIX=""; RESTORE=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)      DRY=1; shift ;;
        --keep-backups) RESTORE=0; shift ;;
        --prefix)       PREFIX="${2%/}"; shift 2 ;;
        -h|--help)      sed -n '2,11p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

DATA_HOME="${PREFIX}${XDG_DATA_HOME:-$HOME/.local/share}"
STATE="${DATA_HOME}/hyprland-dotfiles"
MANIFEST="${STATE}/installed.txt"

run() { if (( DRY )); then printf '   would run: %s\n' "$*"; else "$@"; fi; }
(( DRY )) && warn "dry run — nothing will be removed"

[[ -r "$MANIFEST" ]] || die "no manifest at ${MANIFEST} — was this ever installed?"

if [[ -z "$PREFIX" ]]; then
    if systemctl --user list-unit-files clean-caches.timer --no-legend 2>/dev/null | grep -q .; then
        say "Stopping the housekeeping timer"
        run systemctl --user disable --now clean-caches.timer
    fi
fi

say "Removing installed files"
removed=0
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ -f "$path" || -L "$path" ]]; then
        run rm -f "$path"
        removed=$((removed + 1))
    fi
done < "$MANIFEST"
ok "removed ${removed} files"

if (( RESTORE )); then
    latest=$(find "$STATE" -maxdepth 1 -type d -name 'backup-*' 2>/dev/null | sort | tail -1)
    if [[ -n "$latest" ]]; then
        say "Restoring what was replaced, from $(basename "$latest")"
        count=0
        while IFS= read -r saved; do
            rel="${saved#"$latest"}"
            dest="${PREFIX}${rel}"
            run mkdir -p "$(dirname "$dest")"
            run cp -a "$saved" "$dest"
            count=$((count + 1))
        done < <(find "$latest" -type f 2>/dev/null)
        ok "restored ${count} files"
    else
        say "Nothing to restore — no file was replaced during installation"
    fi
else
    say "--keep-backups: leaving the backups in ${STATE}"
fi

if [[ -z "$PREFIX" ]]; then
    run systemctl --user daemon-reload
fi

echo
say "Not touched"
echo "   ~/.config/hypr/wallpapers   your images"
echo "   companion repositories in ~/Projects, if any were cloned"
echo "   the backups in ${STATE}"
echo
warn "Run 'hyprctl reload' to apply the restored config, or log out and back in."
echo
ok "Uninstall finished."
