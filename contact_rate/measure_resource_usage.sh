#!/usr/bin/env bash
# measure_resource_usage.sh -- CPU% and RSS of the persistent relay/BPA
# processes in the real 4-hop chain (alice -> unibo -> hardy -> bob),
# sampled while apps/sender bursts each payload size through it. Answers
# the "any CPU-load/resource-usage data from the benchmarks?" review
# question -- nothing in this repo measured that before this script.
#
# Processes sampled (all persistent daemons, resolved once at startup via
# pgrep -f on a substring unique to that process's launch command -- see
# resolve_pid()):
#   - alice's uD3TN            (host, distinguished from bob's uD3TN by
#                                "-e dtn://alice.dtn/" in its argv)
#   - bob's uD3TN               ("-e dtn://bob.dtn/")
#   - unibo-bp-cspcl            (node1's CSPCL CLA daemon, host)
#   - hardy-bpa-server           (node2's BPA, host)
#   - charon (alice_ns)         (resolved by its config-file argument;
#                                 `ip netns exec` does not create a new PID
#                                 namespace, only a new network namespace,
#                                 so these PIDs are visible to a plain
#                                 `pgrep -f` run on the host with no netns
#                                 exec of our own needed)
#   - charon (bob_ns)
#
# apps/sender and apps/receiver are NOT sampled: they are short-lived
# per-run processes (the whole point is they start and exit within one
# size's measurement window), not persistent daemons, so a fixed-interval
# poll would catch at most one or two samples of dubious value. The daemon
# list above is the whole story for "resource usage of the DTN stack".
#
# -- Measurement method: ps polling, not /proc/<pid>/stat deltas --
#
# Every SAMPLE_INTERVAL_S (default 0.5s) this script runs
# `ps -o %cpu=,rss= -p <pid>` for each of the six PIDs above and appends
# the result to a per-process, per-payload-size log.
#
# What `ps %cpu` actually is, and why that's an acceptable tradeoff here:
# it is NOT an instantaneous CPU% at sample time. It is
# (accumulated CPU time) / (process elapsed time) as tracked by the
# kernel's scheduler accounting, which procps smooths with a decaying
# average over the last few seconds (see `man ps`, the %CPU description).
# That means a single sample already reflects recent history, not a
# snapshot -- consecutive samples 0.5s apart are correlated, not
# independent, so the "mean" this script reports is a mean of already-
# smoothed values, not a mean of true instantaneous load. The alternative
# (reading /proc/<pid>/stat's utime+stime jiffies directly and
# differencing between two samples, divided by sysconf(_SC_CLK_TCK) and
# wall-clock delta) gives a truer per-interval figure and was considered,
# but is materially more bash code (parsing /proc/<pid>/stat field 14/15,
# handling the process disappearing mid-read, HZ discovery) for a metric
# whose main use here is "which process dominates CPU and by roughly how
# much", not a rigorously interval-accurate profile. `ps` is simpler to
# get right and is what this suite's header-comment convention (see
# test_paced_delivery.sh) asks us to be honest about -- so: `ps`-based,
# smoothed, and documented as such. RSS (`ps -o rss`, KB) has no such
# caveat -- it's a direct point-in-time read of the process's resident set
# from the kernel, not smoothed.
#
# CPU%: this is single-core-relative (a process pinning one core on a
# nproc-core machine reads up to 100%, not 100/nproc%) -- procps'
# convention, not renormalized here. nproc is printed in the report
# header for context.
#
# -- Sampling window per payload size --
#
# Sampling starts just before the receiver is launched and stops once the
# receiver has returned (delivered or timed out), so each size's log
# covers that size's full send+receive window plus the fixed startup
# settle delay already used elsewhere in this suite. Samplers are
# restarted fresh per size so each size's mean/peak is computed from that
# size's own window only, not diluted by idle time between sizes.
#
# Usage: sudo ./measure_resource_usage.sh [output_dir]
# Env overrides: CAN_KBPS=50 TCP_KBPS=100 SIZES="64 256 1024 4096" COUNT=10
#                SAMPLE_INTERVAL_S=0.5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SENDER="$REPO_ROOT/apps/sender"
RECEIVER="$REPO_ROOT/apps/receiver"
SHAPE="$SCRIPT_DIR/shape_links.sh"

OUT_DIR="${1:-$SCRIPT_DIR/results_resource_$(date +%Y%m%d_%H%M%S)}"
PORT=4000
REMOTE=10.0.0.2
CAN_KBPS="${CAN_KBPS:-50}"
TCP_KBPS="${TCP_KBPS:-100}"
read -ra SIZES <<< "${SIZES:-64 256 1024 4096}"
COUNT="${COUNT:-10}"
SAMPLE_INTERVAL_S="${SAMPLE_INTERVAL_S:-0.5}"
RECV_TIMEOUT_S=30

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (ip netns exec / tc require it)" >&2
    exit 1
fi

if [[ ! -x "$SENDER" || ! -x "$RECEIVER" ]]; then
    echo "error: apps/sender or apps/receiver not found -- run: make -C apps" >&2
    exit 1
fi

for ns in alice_ns bob_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        echo "error: network namespace $ns not found -- run DEMO.md Phase 1 first" >&2
        exit 1
    fi
done

# -- Resolve the 6 persistent-daemon PIDs, once, up front --
#
# Each pattern must match exactly one running process. If it matches zero,
# that daemon isn't up (bring up DEMO.md Phases 1-3, T1-T9, first). If it
# matches more than one, the pattern isn't actually distinguishing (e.g.
# two ud3tn instances both matched) and needs tightening -- abort rather
# than silently sampling the wrong PID or averaging across processes.
PROC_NAMES=(alice_ud3tn bob_ud3tn unibo_cspcl hardy_bpa charon_alice charon_bob)
declare -A PROC_PATTERN=(
    [alice_ud3tn]="ud3tn.*-e dtn://alice.dtn/"
    [bob_ud3tn]="ud3tn.*-e dtn://bob.dtn/"
    [unibo_cspcl]="unibo-bp-cspcl"
    [hardy_bpa]="hardy-bpa-server"
    [charon_alice]="charon.*charon-alice.conf"
    [charon_bob]="charon.*charon-bob.conf"
)
declare -A PROC_LABEL=(
    [alice_ud3tn]="alice uD3TN"
    [bob_ud3tn]="bob uD3TN"
    [unibo_cspcl]="unibo-bp-cspcl"
    [hardy_bpa]="hardy-bpa-server"
    [charon_alice]="charon (alice_ns)"
    [charon_bob]="charon (bob_ns)"
)
declare -A PROC_PID

echo "-- resolving persistent-process PIDs --"
resolve_failed=0
for name in "${PROC_NAMES[@]}"; do
    pattern="${PROC_PATTERN[$name]}"
    # -f: match full argv, not just the binary basename -- required to
    # tell the two ud3tn instances and the two charon instances apart.
    mapfile -t matches < <(pgrep -f "$pattern" || true)
    if [[ ${#matches[@]} -eq 0 ]]; then
        echo "error: no process matches pattern for ${PROC_LABEL[$name]} (pgrep -f \"$pattern\") -- is the DEMO.md stack (Phases 1-3, T1-T9) running?" >&2
        resolve_failed=1
        continue
    fi
    if [[ ${#matches[@]} -gt 1 ]]; then
        echo "error: pattern for ${PROC_LABEL[$name]} (pgrep -f \"$pattern\") matched ${#matches[@]} processes (${matches[*]}), not 1 -- pattern is not unique, refine it" >&2
        resolve_failed=1
        continue
    fi
    PROC_PID[$name]="${matches[0]}"
    echo "  ${PROC_LABEL[$name]}: pid ${matches[0]}"
done
if [[ $resolve_failed -eq 1 ]]; then
    echo "error: aborting -- not all expected processes were found running uniquely (see above)" >&2
    exit 1
fi
echo ""

mkdir -p "$OUT_DIR"

SHAPED=0
SAMPLER_PIDS=()
cleanup() {
    for spid in "${SAMPLER_PIDS[@]:-}"; do
        kill "$spid" 2>/dev/null || true
    done
    if [[ $SHAPED -eq 1 ]]; then
        echo ""
        echo "-- removing contact-rate shaping --"
        "$SHAPE" down || true
    fi
}
trap cleanup EXIT

echo "-- applying contact-rate shaping: CAN hops @ ${CAN_KBPS}kbit/s, alice<->unibo @ ${TCP_KBPS}kbit/s --"
"$SHAPE" up "$CAN_KBPS" "$TCP_KBPS"
SHAPED=1
echo ""

NPROC=$(nproc)
echo "Host has $NPROC CPU(s); %CPU below is single-core-relative (procps convention), not divided by NPROC."
echo "Results will be written to: $OUT_DIR"
echo ""

# Appends "<epoch.nanos> <%cpu> <rss_kb>" lines to $2 for pid $1 every
# SAMPLE_INTERVAL_S, until the pid disappears or this loop is killed.
sample_loop() {
    local pid="$1" logfile="$2"
    while kill -0 "$pid" 2>/dev/null; do
        local line
        line=$(ps -o %cpu=,rss= -p "$pid" 2>/dev/null) || break
        # ps prints nothing (empty $line) in the narrow race where the
        # process exits between kill -0 and this ps call -- skip that
        # sample rather than logging a malformed line.
        if [[ -n "$line" ]]; then
            echo "$(date +%s.%N) $line" >> "$logfile"
        fi
        sleep "$SAMPLE_INTERVAL_S"
    done
}

# Prints "mean_cpu peak_cpu peak_rss_kb" for a given per-process log, or
# "N/A N/A N/A" if no samples were captured (e.g. window shorter than one
# SAMPLE_INTERVAL_S -- can happen for very small/fast payloads).
summarize_log() {
    local logfile="$1"
    if [[ ! -s "$logfile" ]]; then
        echo "N/A N/A N/A"
        return
    fi
    awk '
        { cpu_sum += $2; if ($2 > cpu_peak) cpu_peak = $2
          if ($3 > rss_peak) rss_peak = $3; n++ }
        END {
            if (n == 0) { print "N/A N/A N/A"; exit }
            printf "%.1f %.1f %d\n", cpu_sum / n, cpu_peak, rss_peak
        }
    ' "$logfile"
}

printf "%-8s  %-20s  %-9s  %-9s  %-10s\n" "size(B)" "process" "mean%cpu" "peak%cpu" "peak RSS(KB)"
printf "%-8s  %-20s  %-9s  %-9s  %-10s\n" "-------" "-------" "--------" "--------" "------------"

report_rows=()
declare -A SIZE_LOGS

for size in "${SIZES[@]}"; do
    recv_log="$OUT_DIR/size_${size}_traffic.log"

    # Start one sampler per persistent daemon, fresh for this size, so
    # each size's stats reflect only that size's send+receive window.
    SAMPLER_PIDS=()
    for name in "${PROC_NAMES[@]}"; do
        plog="$OUT_DIR/size_${size}_${name}.log"
        : > "$plog"
        SIZE_LOGS[$name]="$plog"
        sample_loop "${PROC_PID[$name]}" "$plog" &
        SAMPLER_PIDS+=("$!")
    done

    ip netns exec bob_ns "$RECEIVER" $PORT $COUNT > "$recv_log" 2>&1 &
    RECV_PID=$!
    sleep 0.3

    ip netns exec alice_ns "$SENDER" $REMOTE $PORT $COUNT $size 0 >> "$recv_log" 2>&1

    waited=0
    while kill -0 $RECV_PID 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $RECV_TIMEOUT_S ]]; then
            kill $RECV_PID 2>/dev/null || true
            break
        fi
    done

    # Small settle delay so the samplers catch any post-delivery
    # bookkeeping (e.g. storage writes, ack processing) before we stop
    # them -- matches this suite's convention elsewhere of not cutting
    # the measurement window off the instant the receiver returns.
    sleep 1

    for spid in "${SAMPLER_PIDS[@]}"; do
        kill "$spid" 2>/dev/null || true
    done
    wait "${SAMPLER_PIDS[@]}" 2>/dev/null || true

    delivered=$(grep -c '^RECV ' "$recv_log" || true)

    for name in "${PROC_NAMES[@]}"; do
        read -r mean_cpu peak_cpu peak_rss <<< "$(summarize_log "${SIZE_LOGS[$name]}")"
        printf "%-8s  %-20s  %-9s  %-9s  %-10s\n" \
            "$size" "${PROC_LABEL[$name]}" "$mean_cpu" "$peak_cpu" "$peak_rss"
        report_rows+=("| $size | ${PROC_LABEL[$name]} | $delivered/$COUNT | $mean_cpu | $peak_cpu | $peak_rss |")
    done
    echo ""
done

report_file="$OUT_DIR/resource_usage_report.md"
{
    echo "# CPU and memory usage of persistent relay/BPA processes"
    echo ""
    echo "CAN hops shaped to ${CAN_KBPS}kbit/s; alice<->unibo shaped to ${TCP_KBPS}kbit/s."
    echo "Host: $NPROC CPU(s). \`%cpu\` via \`ps -o %cpu\`, single-core-relative"
    echo "(a process pinning one core reads up to 100%, not 100/$NPROC%) and"
    echo "smoothed by the kernel/procps over a several-second decaying window --"
    echo "not an instantaneous per-sample reading. RSS via \`ps -o rss\` (KB),"
    echo "a direct point-in-time read, not smoothed. Sampled every"
    echo "${SAMPLE_INTERVAL_S}s across each payload size's send+receive window"
    echo "(fresh sampler per size). See script header for full methodology"
    echo "and why \`ps\` polling was chosen over \`/proc/<pid>/stat\` deltas."
    echo ""
    echo "| payload (B) | process | delivered | mean %cpu | peak %cpu | peak RSS (KB) |"
    echo "| --- | --- | --- | --- | --- | --- |"
    for row in "${report_rows[@]}"; do
        echo "$row"
    done
} > "$report_file"

echo "Per-process, per-size logs and report saved in: $OUT_DIR"
echo "Report: $report_file"
