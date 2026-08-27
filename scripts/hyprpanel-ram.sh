#!/bin/bash
# hyprpanel-ram.sh — memory figures for a custom/ram module in HyprPanel.
# Prints one line of JSON; the keys are substituted into the label and tooltip
# in modules.json.
#
# "Used" is MemTotal - MemAvailable, exactly as the built-in ram module computed
# it, so the number on the bar does not change.
# LC_ALL=C is required: under a comma-decimal locale awk would print "3,58" and
# break the JSON.

export LC_ALL=C

awk '
/^MemTotal:/     { total = $2 }
/^MemFree:/      { free  = $2 }
/^MemAvailable:/ { avail = $2 }
/^Buffers:/      { buf   = $2 }
/^Cached:/       { cached = $2 }
/^SReclaimable:/ { srec  = $2 }
/^SwapTotal:/    { stot  = $2 }
/^SwapFree:/     { sfree = $2 }
END {
    g     = 1048576                 # KiB -> GiB
    used  = total - avail
    cache = cached + srec + buf
    sused = stot - sfree
    printf "{"
    printf "\"used\":\"%.2f GiB\",",        used  / g
    printf "\"pct\":\"%.0f\",",             total ? 100 * used / total : 0
    printf "\"avail\":\"%.2f GiB\",",       avail / g
    printf "\"free\":\"%.2f GiB\",",        free  / g
    printf "\"cache\":\"%.2f GiB\",",       cache / g
    printf "\"total\":\"%.2f GiB\",",       total / g
    printf "\"swap\":\"%.2f / %.2f GiB\",", sused / g, stot / g
    printf "\"swap_pct\":\"%.0f\"",         stot ? 100 * sused / stot : 0
    printf "}\n"
}' /proc/meminfo
