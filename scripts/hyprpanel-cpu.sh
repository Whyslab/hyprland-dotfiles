#!/bin/bash
# hyprpanel-cpu.sh — CPU load and the five hungriest processes, for a
# custom/cpu module in HyprPanel. Prints a single line of JSON.
#
# Percentages come from the DELTA between calls, the way btop does it, rather
# than from `ps %cpu` — which averages over a process's whole lifetime and so
# lies: a daemon that was busy at startup stays at the top for hours. A snapshot
# of the counters is therefore kept in a state file between runs; the first call
# after login reports zeros and fills in on the second, two seconds later.
#
# Total load uses the same formula as HyprPanel's built-in module,
# (total - idle - iowait) / total, so the number on the bar does not change.
#
# Per-process percentages are a share of the WHOLE machine rather than of one
# core, so they never exceed 100% the way top's do. They add up to noticeably
# less than the total: work by processes that were born and died between two
# polls is not counted, and neither is the kernel's own time.
#
# Files are read through cat rather than handed to awk as a /proc/[0-9]*/stat
# glob: processes disappear constantly, and awk aborts on a vanished file
# without reaching END — the module then silently prints nothing. cat just
# skips a file that went away.
#
# LC_ALL=C is required: under a comma-decimal locale awk would print "8,2" and
# break the JSON.

export LC_ALL=C

STATE="${XDG_RUNTIME_DIR:-/tmp}/hyprpanel-cpu-prev"
TOP_N=5

{ cat /proc/stat; cat /proc/[0-9]*/stat; } 2>/dev/null | awk -v state="$STATE" -v topn="$TOP_N" '
# The summary line from /proc/stat. No /proc/<pid>/stat line can be mistaken
# for it: there the first field is always a number (the pid).
$1 == "cpu" && !seen_cpu {
    for (i = 2; i <= 8; i++) total += $i
    idle = $5 + $6
    seen_cpu = 1
    next
}

{
    # The process name sits in parentheses and may ITSELF contain parentheses
    # and spaces ("(Web Content)", "(tmux: server)"), so look for the LAST ")".
    # Other /proc/stat lines (intr, ctxt, cpu0...) have none and drop out here.
    open_p = index($0, "(")
    if (!open_p) next
    close_p = 0
    for (k = length($0); k > 0; k--)
        if (substr($0, k, 1) == ")") { close_p = k; break }
    if (close_p <= open_p) next

    pid  = $1
    comm = substr($0, open_p + 1, close_p - open_p - 1)

    n = split(substr($0, close_p + 2), f, " ")
    if (n < 13) next
    ticks = f[12] + f[13]          # utime + stime (fields 14 and 15 of the whole line)

    cur_ticks[pid] = ticks
    cur_comm[pid]  = comm
}

END {
    while ((getline line < "/proc/cpuinfo") > 0) if (line ~ /^processor/) cores++
    close("/proc/cpuinfo")

    have_prev = 0
    while ((getline line < state) > 0) {
        split(line, a, "\t")
        if (a[1] == "#") { prev_total = a[2]; prev_idle = a[3]; have_prev = 1 }
        else             { prev_ticks[a[1]] = a[2] }
    }
    close(state)

    # A snapshot for the next call: written to a temporary file and swapped in
    # at once, so a concurrent call never reads a half-written one.
    tmp = state ".tmp"
    printf "#\t%d\t%d\n", total, idle > tmp
    for (p in cur_ticks) printf "%s\t%d\n", p, cur_ticks[p] > tmp
    close(tmp)
    system("mv -f " tmp " " state)

    d_total = total - prev_total
    if (!have_prev || d_total <= 0) {
        printf "{\"pct\":\"0\",\"cores\":\"%d\",\"top\":\"  collecting...\"}\n", cores
        exit
    }

    load = 100 * (d_total - (idle - prev_idle)) / d_total
    if (load < 0)   load = 0
    if (load > 100) load = 100

    cnt = 0
    for (p in cur_ticks) {
        if (!(p in prev_ticks)) continue          # the process was just born
        d = cur_ticks[p] - prev_ticks[p]
        if (d <= 0) continue
        cnt++
        dv[cnt] = d; dp[cnt] = p
    }

    # A partial selection sort: only the topn largest are needed.
    lim = (cnt < topn) ? cnt : topn
    for (i = 1; i <= lim; i++) {
        mx = i
        for (j = i + 1; j <= cnt; j++) if (dv[j] > dv[mx]) mx = j
        t = dv[i]; dv[i] = dv[mx]; dv[mx] = t
        t = dp[i]; dp[i] = dp[mx]; dp[mx] = t
    }

    top = ""
    for (i = 1; i <= lim; i++) {
        pct = 100 * dv[i] / d_total
        if (pct < 0.1) continue
        name = cur_comm[dp[i]]
        if (length(name) > 16) name = substr(name, 1, 15) "…"
        top = top sprintf("  %5.1f%%  %-16s %s\\n", pct, name, dp[i])
    }
    if (top == "") top = "  all quiet"
    sub(/\\n$/, "", top)

    printf "{\"pct\":\"%.0f\",\"cores\":\"%d\",\"top\":\"%s\"}\n", load, cores, esc(top)
}

# Escape whatever might turn up in a process name and break the JSON.
function esc(s) {
    gsub(/\\\\/, "\\\\\\\\", s)
    gsub(/"/,    "\\\"",     s)
    gsub(/\t/,   " ",        s)
    return s
}
'
