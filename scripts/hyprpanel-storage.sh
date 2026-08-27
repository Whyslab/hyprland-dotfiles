#!/bin/bash
# hyprpanel-storage.sh — root filesystem usage, for a custom/storage module.
# Prints one line of JSON for the label/tooltip in modules.json.
#
# The percentage is (total - available) / total, the same way the built-in
# storage module computed it, so the number on the bar does not change. That
# figure includes the reserve ext4 keeps for root, which is why the tooltip
# breaks it down:
#   used    = total - available   (what the percentage comes from)
#   data    = actually occupied by files (what df reports)
#   reserve = root's reserve, used - data
# This is why df -h / shows a smaller percentage: it does not count the reserve
# as used.
#
# LC_ALL=C is required: under a comma-decimal locale awk would print "53,32"
# and break the JSON.

export LC_ALL=C

df -B1 --output=size,used,avail,pcent / | awk '
NR == 2 {
    g       = 1073741824            # bytes -> GiB
    total   = $1; data = $2; avail = $3
    dfpct   = $4
    used    = total - avail
    reserve = used - data
    printf "{"
    printf "\"pct\":\"%.0f\",",         total ? 100 * used / total : 0
    printf "\"used\":\"%.2f GiB\",",    used    / g
    printf "\"data\":\"%.2f GiB\",",    data    / g
    printf "\"reserve\":\"%.2f GiB\",", reserve / g
    printf "\"avail\":\"%.2f GiB\",",   avail   / g
    printf "\"total\":\"%.2f GiB\",",   total   / g
    printf "\"dfpct\":\"%s\"",          dfpct
    printf "}\n"
}'
