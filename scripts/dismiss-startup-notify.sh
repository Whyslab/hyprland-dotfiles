#!/bin/bash
# Dismisses the yellow Hyprland notice about the .conf format that appears when
# the session starts. It is emitted after the config has already been parsed, so
# the only thing to do is wait for it and clear all notifications a few times.
for delay in 2 4 8; do
    sleep "$delay"
    hyprctl dismissnotify >/dev/null 2>&1
done
