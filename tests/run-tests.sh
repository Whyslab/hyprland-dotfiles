#!/usr/bin/env bash
# tests/run-tests.sh — the dotfiles test suite.
#
# Nothing here touches a real system: every install runs against a temporary
# --prefix, and no test needs a Hyprland session, a display or root.
#
# Run: bash tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

ok()    { printf '  \033[0;32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
nok()   { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '         %s\n' "$2"; FAIL=$((FAIL+1)); }
group() { printf '\n\033[0;34m==>\033[0m %s\n' "$1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------------------
group "Shell syntax"
# --------------------------------------------------------------------------
while IFS= read -r f; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"
    else nok "bash -n $(basename "$f")" "$(bash -n "$f" 2>&1 | head -1)"; fi
done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*' | sort)

# --------------------------------------------------------------------------
group "Shipped configuration parses"
# --------------------------------------------------------------------------
for f in "$ROOT"/config/hyprpanel/*.json; do
    if jq empty "$f" 2>/dev/null; then ok "valid JSON: $(basename "$f")"
    else nok "invalid JSON: $(basename "$f")" "$(jq empty "$f" 2>&1 | head -1)"; fi
done

# wlogout's layout is a stream of JSON objects, one per line — not an array.
bad=0
while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    jq empty <<<"$line" 2>/dev/null || bad=$((bad+1))
done < "$ROOT/config/wlogout/layout"
(( bad == 0 )) && ok "every wlogout layout line is valid JSON" \
                || nok "$bad malformed lines in the wlogout layout"

if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('$ROOT/config/fontconfig/fonts.conf')" 2>/dev/null; then
    ok "fonts.conf is well-formed XML"
else
    nok "fonts.conf is not well-formed XML"
fi

# --------------------------------------------------------------------------
group "Nothing personal is shipped"
# --------------------------------------------------------------------------
# These files were taken off a working machine. An absolute path or a username
# left in one of them is a bug, not a detail — it breaks the config for
# everyone else and leaks who assembled it.
if hits=$(grep -rniE 'bogdan|dodg1403' "$ROOT" --exclude-dir=.git --exclude='run-tests.sh' --exclude='ci.yml' 2>/dev/null); then
    nok "personal identifier found" "$(head -3 <<<"$hits")"
else
    ok "no personal identifiers"
fi

if hits=$(grep -rnE '/home/[a-z][a-z0-9_-]*/' "$ROOT" --exclude-dir=.git --exclude='*.md' \
             --exclude='run-tests.sh' --exclude='ci.yml' --exclude='btop.conf' 2>/dev/null); then
    nok "hard-coded home path" "$(head -3 <<<"$hits")"
else
    ok "no hard-coded home paths (they are __HOME__ placeholders)"
fi

if hits=$(grep -rlIP '[\x{0400}-\x{04FF}]' "$ROOT" --exclude-dir=.git --exclude='*.ru.md' --exclude='README.md' 2>/dev/null); then
    nok "untranslated text" "$(head -3 <<<"$hits")"
else
    ok "everything user-facing is English"
fi

# --------------------------------------------------------------------------
group "Every placeholder is substituted on install"
# --------------------------------------------------------------------------
# A config that reaches ~/.config still holding __HOME__ produces a path that
# does not exist — and Hyprland fails that one line silently.
SB="$TMP/full"
if "$ROOT/install.sh" --prefix "$SB" --all >/dev/null 2>&1; then
    ok "install.sh --all succeeds"
else
    nok "install.sh --all failed" "$("$ROOT/install.sh" --prefix "$SB" --all 2>&1 | tail -3)"
fi

if left=$(grep -rl '__HOME__' "$SB" 2>/dev/null); then
    nok "placeholders left in installed files" "$(head -3 <<<"$left")"
else
    ok "no __HOME__ survives into the installed files"
fi

for f in .config/hypr/hyprland.conf .config/hyprpanel/modules.json .config/rofi/config.rasi \
         .config/wlogout/style.css .config/hypr/scripts/wallpaper.sh; do
    [[ -e "$SB$HOME/$f" ]] && ok "installed: ~/$f" || nok "not installed: ~/$f"
done

# --------------------------------------------------------------------------
group "Modules install only what they claim"
# --------------------------------------------------------------------------
# Picking one module and getting another one's files is the failure that makes
# a modular installer worse than no installer.
declare -A EXPECT=(
  [menus]=".config/rofi/config.rasi"
  [terminal]=".config/kitty/kitty.conf"
  [fonts]=".config/fontconfig/fonts.conf"
  [core]=".config/hypr/hyprland.conf"
)
declare -A FORBID=(
  [menus]=".config/kitty/kitty.conf"
  [terminal]=".config/rofi/config.rasi"
  [fonts]=".config/hypr/hyprland.conf"
  [core]=".config/fontconfig/fonts.conf"
)
for m in menus terminal fonts core; do
    sb="$TMP/mod-$m"
    "$ROOT/install.sh" --prefix "$sb" --modules "$m" >/dev/null 2>&1
    if [[ -e "$sb$HOME/${EXPECT[$m]}" ]]; then ok "${m}: installs ${EXPECT[$m]}"
    else nok "${m}: did not install ${EXPECT[$m]}"; fi
    if [[ -e "$sb$HOME/${FORBID[$m]}" ]]; then nok "${m}: also installed ${FORBID[$m]}"
    else ok "${m}: leaves ${FORBID[$m]} alone"; fi
done

if out=$("$ROOT/install.sh" --prefix "$TMP/bad" --modules nonsense 2>&1); then
    nok "an unknown module should be refused"
else
    grep -q "no such module" <<<"$out" && ok "an unknown module is refused clearly" \
        || nok "an unknown module gives no clear message" "$(head -1 <<<"$out")"
fi

# --------------------------------------------------------------------------
group "Uninstall restores what it replaced"
# --------------------------------------------------------------------------
# The promise of the backup directory is the whole reason it is safe to try
# these dotfiles on a machine you already configured.
SB2="$TMP/restore"
mkdir -p "$SB2$HOME/.config/hypr" "$SB2$HOME/.config/kitty"
echo "MY OWN CONFIG" > "$SB2$HOME/.config/hypr/hyprland.conf"
echo "MY OWN KITTY"  > "$SB2$HOME/.config/kitty/kitty.conf"
"$ROOT/install.sh" --prefix "$SB2" --modules core,terminal >/dev/null 2>&1

grep -q "MY OWN CONFIG" "$SB2$HOME/.config/hypr/hyprland.conf" \
    && nok "install did not replace the existing config" \
    || ok "install replaced the existing config"

"$ROOT/uninstall.sh" --prefix "$SB2" >/dev/null 2>&1
if grep -q "MY OWN CONFIG" "$SB2$HOME/.config/hypr/hyprland.conf" 2>/dev/null \
   && grep -q "MY OWN KITTY" "$SB2$HOME/.config/kitty/kitty.conf" 2>/dev/null; then
    ok "uninstall restored both original files"
else
    nok "uninstall did not restore the originals"
fi

# A wallpaper the user put there is not ours to delete.
SB3="$TMP/wallpapers"
"$ROOT/install.sh" --prefix "$SB3" --modules wallpapers >/dev/null 2>&1
echo "an image" > "$SB3$HOME/.config/hypr/wallpapers/mine.png"
"$ROOT/uninstall.sh" --prefix "$SB3" >/dev/null 2>&1
[[ -e "$SB3$HOME/.config/hypr/wallpapers/mine.png" ]] \
    && ok "uninstall keeps the user's own wallpapers" \
    || nok "uninstall deleted a user wallpaper"
[[ -e "$SB3$HOME/.config/hypr/wallpapers/README.md" ]] \
    && nok "uninstall left our own note behind" \
    || ok "uninstall removes the note it added"

# --------------------------------------------------------------------------
group "Panel modules emit valid JSON"
# --------------------------------------------------------------------------
# HyprPanel parses one line of JSON per poll. A module that prints a bare
# number, an error, or nothing at all takes the widget off the bar silently.
for m in cpu ram storage; do
    script="$ROOT/scripts/hyprpanel-${m}.sh"
    out=$("$script" 2>/dev/null)
    if jq empty <<<"$out" 2>/dev/null; then
        lines=$(printf '%s' "$out" | grep -c '' || true)
        (( lines == 1 )) && ok "hyprpanel-${m}.sh -> one line of valid JSON" \
                         || nok "hyprpanel-${m}.sh printed ${lines} lines"
    else
        nok "hyprpanel-${m}.sh did not print valid JSON" "$(head -c 120 <<<"$out")"
    fi
done

# The keys the bar substitutes have to exist, or the tooltip shows {placeholders}.
for m in cpu ram storage; do
    out=$("$ROOT/scripts/hyprpanel-${m}.sh" 2>/dev/null)
    tooltip=$(jq -r --arg m "custom/${m}" '.[$m].tooltip // empty' "$ROOT/config/hyprpanel/modules.json" 2>/dev/null)
    label=$(jq -r --arg m "custom/${m}" '.[$m].label // empty' "$ROOT/config/hyprpanel/modules.json" 2>/dev/null)
    missing=""
    for key in $(grep -oP '\{\K[a-z_]+(?=\})' <<<"${tooltip}${label}" | sort -u); do
        jq -e --arg k "$key" 'has($k)' <<<"$out" >/dev/null 2>&1 || missing+="$key "
    done
    [[ -z "$missing" ]] && ok "hyprpanel-${m}.sh provides every key the bar asks for" \
                        || nok "hyprpanel-${m}.sh is missing keys: $missing"
done

# --------------------------------------------------------------------------
group "Sizes do not depend on the system locale"
# --------------------------------------------------------------------------
# Under a comma-decimal locale awk prints "5,24" and the JSON stops parsing.
for loc in C ru_RU.UTF-8 de_DE.UTF-8; do
    out=$(LC_ALL="$loc" "$ROOT/scripts/hyprpanel-ram.sh" 2>/dev/null)
    if jq empty <<<"$out" 2>/dev/null; then ok "hyprpanel-ram.sh under LC_ALL=${loc}"
    else nok "hyprpanel-ram.sh breaks under LC_ALL=${loc}" "$(head -c 100 <<<"$out")"; fi
done

# --------------------------------------------------------------------------
group "The wallhaven fetcher validates its input"
# --------------------------------------------------------------------------
printf 'not-an-id-at-all\n' > "$TMP/bad.list"
out=$("$ROOT/fetch-wallhaven.sh" --list "$TMP/bad.list" --dest "$TMP/wp" --dry-run 2>&1)
grep -q "not a wallhaven id" <<<"$out" && ok "a malformed id is rejected, not fetched" \
    || nok "a malformed id was not caught" "$(head -2 <<<"$out")"

printf '# only a comment\n\n' > "$TMP/empty.list"
if "$ROOT/fetch-wallhaven.sh" --list "$TMP/empty.list" --dest "$TMP/wp" --dry-run >/dev/null 2>&1; then
    ok "a list of only comments is handled"
else
    nok "a comment-only list should not be an error"
fi

# --------------------------------------------------------------------------
group "Random wallpaper mode"
# --------------------------------------------------------------------------
# The mode is three switches in one state file, and two hooks that must stay
# silent until a switch is on. Everything below runs against a fake HOME: the
# lock target is only a symlink, so no compositor and no daemon are needed.
WP="$TMP/home"
mkdir -p "$WP/.config/hypr/wallpapers" "$WP/sddm"
for n in a b c; do printf 'x' > "$WP/.config/hypr/wallpapers/$n.png"; done
wp() { HOME="$WP" WALLPAPER_SDDM_DIR="$WP/sddm" bash "$ROOT/scripts/wallpaper.sh" "$@" 2>/dev/null; }
lock_now() { basename "$(readlink "$WP/.local/state/hypr-wallpaper/lock.img" 2>/dev/null)"; }

[[ "$(wp random status)" == "desktop=off
lock=off
sddm=off" ]] && ok "every switch starts off" || nok "the mode is on by default"

wp random lock on >/dev/null
[[ "$(wp random status)" == "desktop=off
lock=on
sddm=off" ]] && ok "one switch on leaves the others alone" \
             || nok "switching one target on changed another"

[[ -n "$(lock_now)" ]] && ok "switching on applies an image right away" \
                       || nok "switching on left the target unset"

wp random lock toggle >/dev/null
[[ "$(wp random status)" == *"lock=off"* ]] && ok "toggle switches back off" \
                                            || nok "toggle did not switch off"

wp random all on >/dev/null
wp random all toggle >/dev/null
[[ "$(wp random status)" == "desktop=off
lock=off
sddm=off" ]] && ok "'all' toggles everything off when anything is on" \
             || nok "'all' did not switch everything off"

# The hook that runs at login and at lock: a no-op while the switch is off, or
# it would fight with the image the user picked by hand.
wp random lock on >/dev/null
wp set lock "$WP/.config/hypr/wallpapers/a.png" >/dev/null
[[ "$(wp random status)" == *"lock=off"* ]] && ok "picking an image by hand switches the mode off" \
                                            || nok "a hand-picked image left the mode on"
wp auto >/dev/null
[[ "$(lock_now)" == "a.png" ]] && ok "auto leaves a target whose switch is off" \
                               || nok "auto changed a target that was switched off"

# shuffle ignores the switch — it is the explicit "give me another one" command.
wp shuffle lock >/dev/null
[[ "$(lock_now)" != "a.png" ]] && ok "shuffle re-rolls whatever the switch says" \
                               || nok "shuffle did nothing"

# Two images in a row being the same reads as a broken feature, not as chance.
wp random lock on >/dev/null
repeats=0; prev=""
for _ in $(seq 15); do
    wp auto lock >/dev/null
    cur="$(lock_now)"
    [[ "$cur" == "$prev" ]] && repeats=$((repeats+1))
    prev="$cur"
done
(( repeats == 0 )) && ok "auto never repeats the current image" \
                   || nok "auto repeated the current image $repeats times"

# --------------------------------------------------------------------------
printf '\n\033[0;34m==>\033[0m Result: \033[0;32m%d passed\033[0m, ' "$PASS"
if (( FAIL )); then printf '\033[0;31m%d failed\033[0m\n\n' "$FAIL"; exit 1
else printf '0 failed\n\n'; exit 0; fi
