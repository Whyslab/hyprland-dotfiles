#!/bin/bash
# sysmon.sh — btop in the special:sysmon workspace, on top of whatever is focused.
# Bound to SUPER+` and to clicks on the monitoring modules in HyprPanel.
#
# btop starts with the session (exec-once = sysmon.sh start in hyprland.conf) and
# lives hidden in the special workspace. That way the graphs are already full of
# history the first time it is summoned, instead of starting from nothing.
#
# Modes:
#   sysmon.sh start  — autostart: bring btop up HIDDEN, if it is not running.
#   sysmon.sh        — hotkey or click: show or hide it; if the process did die
#                      (Ctrl+Shift+W, a crash) bring it back up visible.

CLASS="btop-scratch"
WS="sysmon"
# A separate kitty config: smaller padding (or btop does not fit) and Esc = hide
KITTY_CONF="$HOME/.config/hypr/scripts/btop-scratch.kitty.conf"
# A marker for the last launch: the window does not appear instantly, and
# without it a keypress right after login would create a second instance.
STAMP="${XDG_RUNTIME_DIR:-/tmp}/sysmon-launched"
GRACE=5

running() {
    hyprctl clients -j | jq -e --arg c "$CLASS" 'any(.[]; .class == $c)' >/dev/null
}

# true if the launch was less than GRACE seconds ago and the window is still coming
just_launched() {
    [ -f "$STAMP" ] || return 1
    [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt "$GRACE" ]
}

# $1 — exec rules, e.g. "workspace special:sysmon silent"
launch() {
    touch "$STAMP"
    hyprctl dispatch exec "[$1] kitty --class $CLASS --config $KITTY_CONF -e btop"
}

case "$1" in
start)
    # Autostart. silent is required: without it Hyprland opens the special
    # workspace itself, and btop pops up over the whole screen during login.
    running || just_launched || launch "workspace special:$WS silent"
    ;;
*)
    if ! running && ! just_launched; then
        # A cold start after a crash. Deliberately without silent and without
        # toggle: Hyprland focuses the new window and opens the special
        # workspace itself once it appears. Toggling in advance would open the
        # workspace while it is still empty.
        launch "workspace special:$WS"
    else
        # The window exists — or autostart is quietly bringing it up and it is
        # about to. In the second case toggling without waiting would do nothing
        # useful: an empty special workspace closes itself and the keypress is
        # wasted.
        for _ in $(seq 30); do
            running && break
            sleep 0.1
        done
        running && hyprctl dispatch togglespecialworkspace "$WS"
    fi
    ;;
esac
