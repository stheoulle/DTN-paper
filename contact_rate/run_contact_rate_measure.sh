#!/usr/bin/env bash
# run_contact_rate_measure.sh — achieved throughput vs. the modeled 50/100
# kbit/s contact rates, end-to-end across the real 4-hop chain
# (alice -> unibo -> hardy -> bob).
#
# Ties together the other three scripts in this folder:
#   1. shape_links.sh    up    -- actually enforce the contact plan's rates
#   2. (this script)            -- reuses apps/sender & apps/receiver (the
#                                  same binaries apps/measure.sh drives) to
#                                  burst each payload size through the real
#                                  netns/Charon/BP chain and measure
#                                  achieved throughput
#   3. ceiling.py               -- computes the theoretical ceiling for the
#                                  same payload size at the same shaped rate
#   4. shape_links.sh    down  -- always removed on exit, including on error
#
# Prerequisites: same as apps/measure.sh -- full stack up (DEMO.md Phase
# 1-3), apps/sender & apps/receiver built (make -C apps), run as root.
#
# Note on timing: apps/sender fires all COUNT packets back-to-back with
# zero pacing (interval_ms=0). Under a genuinely shaped link that just
# queues them for the link to drain over time rather than delivering them
# near-simultaneously, so the per-size wait budget below is derived from
# ceiling.py's own per-bundle time estimate (times COUNT, times a safety
# margin) instead of a fixed timeout -- a fixed value large enough for
# small payloads is nowhere near enough once the theoretical drain time
# for COUNT large payloads at a slow shaped rate exceeds it outright.
#
# Usage: sudo ./run_contact_rate_measure.sh [output_dir]
# Env overrides: CAN_KBPS=50 TCP_KBPS=100 SIZES="64 256 1024 4096" COUNT=10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SENDER="$REPO_ROOT/apps/sender"
RECEIVER="$REPO_ROOT/apps/receiver"
SHAPE="$SCRIPT_DIR/shape_links.sh"
CEILING="$SCRIPT_DIR/ceiling.py"

OUT_DIR="${1:-$SCRIPT_DIR/results_$(date +%Y%m%d_%H%M%S)}"
PORT=4000
REMOTE=10.0.0.2
CAN_KBPS="${CAN_KBPS:-50}"
TCP_KBPS="${TCP_KBPS:-100}"
read -ra SIZES <<< "${SIZES:-64 256 1024 4096}"
COUNT="${COUNT:-10}"

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (ip netns exec / tc require it)" >&2
    exit 1
fi

if [[ ! -x "$SENDER" || ! -x "$RECEIVER" ]]; then
    echo "error: apps/sender or apps/receiver not found — run: make -C apps" >&2
    exit 1
fi

for ns in alice_ns bob_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        echo "error: network namespace $ns not found — run DEMO.md Phase 1 first" >&2
        exit 1
    fi
done

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

echo "-- applying contact-rate shaping: CAN hops @ ${CAN_KBPS}kbit/s, alice<->unibo @ ${TCP_KBPS}kbit/s --"
"$SHAPE" up "$CAN_KBPS" "$TCP_KBPS"
SHAPED=1
echo ""

echo "Results will be written to: $OUT_DIR"
echo ""
printf "%-10s  %-12s  %-12s  %-14s  %-14s  %-10s  %-10s\n" \
    "size(B)" "delivered" "mean(ms)" "achieved kB/s" "ceiling kB/s" "%% of ceiling" "timeout(s)"
printf "%-10s  %-12s  %-12s  %-14s  %-14s  %-10s  %-10s\n" \
    "-------" "---------" "--------" "-------------" "------------" "-----------" "----------"

report_rows=()

for size in "${SIZES[@]}"; do
    logfile="$OUT_DIR/size_${size}.log"

    # Computed up front, not just for the final report: apps/sender fires
    # all COUNT packets back-to-back with zero pacing (interval_ms=0), so
    # under a genuinely shaped link they queue and drain over time rather
    # than arriving near-simultaneously. A fixed TIMEOUT doesn't scale with
    # that drain time -- at larger payloads/lower rates, the *theoretical
    # best case* for draining COUNT packets can itself exceed a fixed 30s,
    # killing the receiver while bundles are still legitimately in flight
    # and producing an artificially low "achieved" figure from a truncated
    # window instead of a real sustained-throughput measurement. Scale the
    # wait budget from the ceiling model's own per-bundle time estimate
    # instead, with a safety margin since real overhead runs well above
    # the theoretical best case (observed ~3-4x in practice).
    ceiling_csv=$(python3 "$CEILING" --csv --sweep "$size" --can-kbps "$CAN_KBPS" \
        --tcp-kbps "$TCP_KBPS" | tail -1)
    ceiling_kBps=$(echo "$ceiling_csv" | cut -d',' -f4)
    per_bundle_time_s=$(echo "$ceiling_csv" | cut -d',' -f5)
    size_timeout=$(python3 -c "
import math
per_bundle = $per_bundle_time_s
count = $COUNT
margin = 5.0
floor_s = 15
print(max(floor_s, math.ceil(per_bundle * count * margin)))
")

    ip netns exec bob_ns "$RECEIVER" $PORT $COUNT > "$logfile" 2>&1 &
    RECV_PID=$!
    sleep 0.3

    t_start=$(date +%s%N)
    ip netns exec alice_ns "$SENDER" $REMOTE $PORT $COUNT $size 0 >> "$logfile" 2>&1
    t_send_done=$(date +%s%N)

    waited=0
    while kill -0 $RECV_PID 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $size_timeout ]]; then
            kill $RECV_PID 2>/dev/null || true
            break
        fi
    done
    t_end=$(date +%s%N)

    delivered=$(grep -c '^RECV ' "$logfile" || true)
    mean_ms=$(grep 'mean=' "$logfile" | grep -oP 'mean=\K[0-9.]+' || echo "N/A")

    elapsed_ns=$((t_end - t_start))
    elapsed_s=$(python3 -c "print($elapsed_ns / 1e9)")
    total_bytes=$((delivered * size))

    if [[ $delivered -gt 0 ]]; then
        achieved_kBps=$(python3 -c "print(round(($total_bytes / $elapsed_s) / 1000, 2))")
    else
        achieved_kBps="0"
    fi

    pct=$(python3 -c "
achieved = $achieved_kBps
ceiling = $ceiling_kBps
print(round(100 * achieved / ceiling, 1) if ceiling > 0 else 0)
")

    printf "%-10s  %-12s  %-12s  %-14s  %-14s  %-10s  %-10s\n" \
        "$size" "$delivered/$COUNT" "$mean_ms" "$achieved_kBps" "$ceiling_kBps" "${pct}%" "$size_timeout"

    report_rows+=("| $size | $delivered/$COUNT | $mean_ms | $achieved_kBps | $ceiling_kBps | ${pct}% | ${size_timeout}s |")
done

report_file="$OUT_DIR/contact_rate_report.md"
{
    echo "# Achieved throughput vs. modeled contact rate"
    echo ""
    echo "CAN hops (unibo<->hardy, hardy<->bob) shaped to ${CAN_KBPS}kbit/s;"
    echo "alice<->unibo shaped to ${TCP_KBPS}kbit/s. End-to-end, real 4-hop chain."
    echo ""
    echo "| payload (B) | delivered | mean latency (ms) | achieved kB/s | ceiling kB/s | % of ceiling | timeout used |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    for row in "${report_rows[@]}"; do
        echo "$row"
    done
} > "$report_file"

echo ""
echo "Per-packet logs and report saved in: $OUT_DIR"
echo "Report: $report_file"
