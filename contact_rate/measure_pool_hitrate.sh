#!/usr/bin/env bash
# measure_pool_hitrate.sh -- connection-pool hit-rate metrics for the
# unibo-bp-cspcl daemon's outbound pool (node1's link to hardy), under
# the same paced 1024B/4096B multi-fragment scenario
# test_paced_delivery.sh already uses (see this folder's README,
# "Connection churn under back-to-back multi-fragment bundles" -- the
# reliability story this reuses the same load pattern from).
#
# Reads pool counters via the live unibo-bp-cspcl process itself, not a
# unit test: cspcl_daemon.c (see cspcl/unibo-integration/src/cspcl_daemon.c)
# installs a SIGUSR1 handler that calls the real cspcl_conn_pool_get_stats()
# accessor (cspcl/src/cspcl.h) and logs one line of the form:
#   [cspcla ...] conn_pool stats (SIGUSR1): hits=H misses=M evictions=E
#   invalidations=I connect_failures=F hit_rate=R
# to its own stderr. This script finds the running unibo-bp-cspcl PID,
# signals it before and after the send, and diffs the two snapshots so
# the reported numbers cover only this run's traffic (the daemon's pool
# is a single long-lived instance shared across every run against it,
# so an un-diffed snapshot would include whatever earlier runs left
# behind).
#
# Requires: unibo-bp-cspcl was rebuilt after the SIGUSR1 handler was
# added (see DEMO.md T4's build commands) and its stderr is being
# captured to a file -- this script does not start or manage the demo
# stack itself, matching test_paced_delivery.sh and
# run_contact_rate_measure.sh's convention of assuming Phases 1-3
# (T1-T9) are already up. Point UNIBO_LOG at wherever T4's terminal
# output was redirected, e.g.:
#   ./build/unibo-bp-cspcl 1 10 can 2001 /tmp/unibo-node1 \
#       > /tmp/unibo-cspcl.log 2>&1 &
#
# Usage: sudo ./measure_pool_hitrate.sh [output_dir]
# Env overrides: CAN_KBPS=50 TCP_KBPS=100 SIZES="1024 4096" COUNT=10
#                PACE_MARGIN=1.5 UNIBO_LOG=/tmp/unibo-cspcl.log
#                UNIBO_PID_PATTERN="unibo-bp-cspcl"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SENDER="$REPO_ROOT/apps/sender"
RECEIVER="$REPO_ROOT/apps/receiver"
SHAPE="$SCRIPT_DIR/shape_links.sh"
CEILING="$SCRIPT_DIR/ceiling.py"

OUT_DIR="${1:-$SCRIPT_DIR/results_pool_hitrate_$(date +%Y%m%d_%H%M%S)}"
PORT=4000
REMOTE=10.0.0.2
CAN_KBPS="${CAN_KBPS:-50}"
TCP_KBPS="${TCP_KBPS:-100}"
read -ra SIZES <<< "${SIZES:-1024 4096}"
COUNT="${COUNT:-10}"
PACE_MARGIN="${PACE_MARGIN:-0}"
UNIBO_LOG="${UNIBO_LOG:-/tmp/unibo-cspcl.log}"
UNIBO_PID_PATTERN="${UNIBO_PID_PATTERN:-unibo-bp-cspcl}"
STATS_WAIT_S=3

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

UNIBO_PID="$(pgrep -f "$UNIBO_PID_PATTERN" | head -1 || true)"
if [[ -z "$UNIBO_PID" ]]; then
    echo "error: no process matching '$UNIBO_PID_PATTERN' found -- start DEMO.md T4" \
        "(after rebuilding unibo-bp-cspcl with the SIGUSR1 pool-stats handler)" >&2
    exit 1
fi
if [[ ! -f "$UNIBO_LOG" ]]; then
    echo "error: UNIBO_LOG=$UNIBO_LOG not found -- redirect unibo-bp-cspcl's stderr to a" \
        "file when starting T4 (see this script's header) and set UNIBO_LOG accordingly" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

SHAPED=0
cleanup() {
    if [[ $SHAPED -eq 1 ]]; then
        echo ""
        echo "-- removing contact-rate shaping --"
        "$SHAPE" down || true
    fi
}
trap cleanup EXIT

# Sends SIGUSR1 to the unibo-bp-cspcl daemon and returns the LAST
# "conn_pool stats" line that appears in UNIBO_LOG afterwards (waits up
# to STATS_WAIT_S for the (non-signal-handler) main loop to notice the
# flag and log it -- see cspcl_daemon.c's daemon_stats_signal_handler /
# dump_pool_stats).
dump_stats() {
    local before_lines
    before_lines=$(wc -l < "$UNIBO_LOG")
    kill -USR1 "$UNIBO_PID"
    local waited=0
    while (( waited < STATS_WAIT_S * 10 )); do
        local new_line
        new_line=$(tail -n +"$((before_lines + 1))" "$UNIBO_LOG" | grep "conn_pool stats" | tail -1 || true)
        if [[ -n "$new_line" ]]; then
            echo "$new_line"
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    echo ""
    return 1
}

# Parses "hits=H misses=M evictions=E invalidations=I connect_failures=F"
# (ignores the leading timestamp/reason and trailing hit_rate=... field,
# which we recompute ourselves from the pre/post diff instead of reusing
# the daemon's own un-diffed hit_rate).
parse_field() {
    local line="$1" field="$2"
    echo "$line" | grep -oP "(?<=${field}=)[0-9]+" || echo ""
}

echo "Connection-pool hit-rate under paced delivery (unibo-bp-cspcl outbound pool)"
echo "CAN hops shaped to ${CAN_KBPS}kbit/s; alice<->unibo shaped to ${TCP_KBPS}kbit/s."
echo "unibo-bp-cspcl pid=$UNIBO_PID, log=$UNIBO_LOG"
echo ""
printf "%-8s  %-10s  %-6s  %-6s  %-10s  %-13s  %-8s\n" \
    "size(B)" "delivered" "hits" "misses" "evictions" "invalidations" "hit_rate"
printf "%-8s  %-10s  %-6s  %-6s  %-10s  %-13s  %-8s\n" \
    "-------" "---------" "----" "------" "---------" "-------------" "--------"

echo "-- applying contact-rate shaping: CAN hops @ ${CAN_KBPS}kbit/s, alice<->unibo @ ${TCP_KBPS}kbit/s --"
"$SHAPE" up "$CAN_KBPS" "$TCP_KBPS"
SHAPED=1
echo ""

report_rows=()
exit_code=0

for size in "${SIZES[@]}"; do
    logfile="$OUT_DIR/size_${size}_pool.log"

    ceiling_csv=$(python3 "$CEILING" --csv --sweep "$size" --can-kbps "$CAN_KBPS" \
        --tcp-kbps "$TCP_KBPS" | tail -1)
    per_bundle_time_s=$(echo "$ceiling_csv" | cut -d',' -f5)
    pace_ms=$(python3 -c "
per_bundle = $per_bundle_time_s
margin = $PACE_MARGIN
floor_ms = 200
print(max(floor_ms, round(per_bundle * margin * 1000)))
")
    recv_timeout=$(python3 -c "
import math
pace = $pace_ms / 1000
count = $COUNT
per_bundle = $per_bundle_time_s
print(max(15, math.ceil(count * pace + per_bundle * 5)))
")

    before_stats_line="$(dump_stats || true)"
    before_hits=$(parse_field "$before_stats_line" hits); before_hits=${before_hits:-0}
    before_misses=$(parse_field "$before_stats_line" misses); before_misses=${before_misses:-0}
    before_evictions=$(parse_field "$before_stats_line" evictions); before_evictions=${before_evictions:-0}
    before_invalidations=$(parse_field "$before_stats_line" invalidations); before_invalidations=${before_invalidations:-0}

    ip netns exec bob_ns "$RECEIVER" $PORT $COUNT > "$logfile" 2>&1 &
    RECV_PID=$!
    sleep 0.3

    ip netns exec alice_ns "$SENDER" $REMOTE $PORT $COUNT $size $pace_ms >> "$logfile" 2>&1

    waited=0
    while kill -0 $RECV_PID 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $recv_timeout ]]; then
            kill $RECV_PID 2>/dev/null || true
            break
        fi
    done

    delivered=$(grep -c '^RECV ' "$logfile" || true)

    after_stats_line="$(dump_stats || true)"
    after_hits=$(parse_field "$after_stats_line" hits); after_hits=${after_hits:-0}
    after_misses=$(parse_field "$after_stats_line" misses); after_misses=${after_misses:-0}
    after_evictions=$(parse_field "$after_stats_line" evictions); after_evictions=${after_evictions:-0}
    after_invalidations=$(parse_field "$after_stats_line" invalidations); after_invalidations=${after_invalidations:-0}

    d_hits=$((after_hits - before_hits))
    d_misses=$((after_misses - before_misses))
    d_evictions=$((after_evictions - before_evictions))
    d_invalidations=$((after_invalidations - before_invalidations))
    d_total=$((d_hits + d_misses))

    if [[ $d_total -gt 0 ]]; then
        hit_rate=$(python3 -c "print(round(100 * $d_hits / $d_total, 1))")
    else
        hit_rate="N/A"
        echo "warning: no pool activity observed for size=$size (SIGUSR1 dump may have failed)" >&2
        exit_code=1
    fi

    printf "%-8s  %-10s  %-6s  %-6s  %-10s  %-13s  %-8s\n" \
        "$size" "$delivered/$COUNT" "$d_hits" "$d_misses" "$d_evictions" "$d_invalidations" "${hit_rate}%"

    report_rows+=("| $size | $delivered/$COUNT | $d_hits | $d_misses | $d_evictions | $d_invalidations | ${hit_rate}% |")
done

report_file="$OUT_DIR/pool_hitrate_report.md"
{
    echo "# Connection-pool hit rate under paced delivery"
    echo ""
    echo "unibo-bp-cspcl outbound pool (node1 -> hardy), pace margin ${PACE_MARGIN}x,"
    echo "CAN hops shaped to ${CAN_KBPS}kbit/s, alice<->unibo shaped to ${TCP_KBPS}kbit/s."
    echo "hits/misses/evictions/invalidations are diffs across this run only (the daemon's"
    echo "pool is long-lived and shared across every run against it)."
    echo ""
    echo "| payload (B) | delivered | hits | misses | evictions | invalidations | hit rate |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    for row in "${report_rows[@]}"; do
        echo "$row"
    done
} > "$report_file"

echo ""
echo "Report: $report_file"
echo "Per-size logs saved in: $OUT_DIR"

exit $exit_code
