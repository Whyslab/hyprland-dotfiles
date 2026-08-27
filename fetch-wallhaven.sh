#!/usr/bin/env bash
# fetch-wallhaven.sh — download the wallhaven images listed in wallpapers.list.
#
# The URL is derived from the id alone, so no API key and no account are needed:
#   https://w.wallhaven.cc/full/<first two characters>/wallhaven-<id>.<ext>
# The extension is not part of the id, so both .jpg and .png are tried.
#
#   ./fetch-wallhaven.sh                    read ./wallpapers.list
#   ./fetch-wallhaven.sh --list other.list  read another file
#   ./fetch-wallhaven.sh --dest DIR         download somewhere else
#   ./fetch-wallhaven.sh --dry-run          print the URLs, download nothing
#
# Nothing here is affiliated with wallhaven. Check the licence of an image
# before doing anything with it beyond looking at your own desktop.

set -Eeuo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
say()  { printf '%b\n' "${BLUE}==>${NC} $*"; }
ok()   { printf '%b\n' "${GREEN}  ok${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}  !!${NC} $*"; }
die()  { printf '%b\n' "${RED}error:${NC} $*" >&2; exit 1; }

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIST="${SELF_DIR}/wallpapers.list"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/wallpapers"
DRY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)    LIST="$2"; shift 2 ;;
        --dest)    DEST="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

command -v curl >/dev/null || die "curl is not installed"
[[ -r "$LIST" ]] || die "no list at ${LIST} — copy wallpapers.list.example to wallpapers.list"

(( DRY )) || mkdir -p "$DEST"
say "List: ${LIST}"
say "Into: ${DEST}"

downloaded=0; skipped=0; failed=0

while IFS= read -r line; do
    id="${line%%#*}"                      # strip a trailing comment
    id="$(tr -d '[:space:]' <<<"$id")"
    [[ -n "$id" ]] || continue
    if [[ ! "$id" =~ ^[a-zA-Z0-9]{6}$ ]]; then
        warn "not a wallhaven id, skipping: ${id}"
        continue
    fi

    existing=$(find "$DEST" -maxdepth 1 -name "wallhaven-${id}.*" 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    got=0
    for ext in jpg png; do
        url="https://w.wallhaven.cc/full/${id:0:2}/wallhaven-${id}.${ext}"
        if (( DRY )); then
            code=$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 15 "$url" || echo 000)
            if [[ "$code" == "200" ]]; then
                printf '   %s\n' "$url"; got=1; break
            fi
            continue
        fi
        tmp="${DEST}/.wallhaven-${id}.${ext}.part"
        if curl -fsSL --max-time 120 -o "$tmp" "$url" 2>/dev/null; then
            mv -f "$tmp" "${DEST}/wallhaven-${id}.${ext}"
            ok "wallhaven-${id}.${ext}"
            got=1; downloaded=$((downloaded + 1))
            break
        fi
        rm -f "$tmp"
    done

    if (( ! got )); then
        warn "could not fetch ${id} (removed, or not a .jpg/.png)"
        failed=$((failed + 1))
    fi
done < "$LIST"

echo
if (( DRY )); then
    say "Dry run — nothing was downloaded."
else
    say "Downloaded ${downloaded}, already present ${skipped}, failed ${failed}."
    (( downloaded )) && echo "   Cycle through them with SUPER+W, or pick one with SUPER+SHIFT+W."
fi
