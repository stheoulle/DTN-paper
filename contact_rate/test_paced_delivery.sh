#!/usr/bin/env bash
# test_paced_delivery.sh -- regression check + throughput measurement:
# confirm the full 4-hop chain (alice -> unibo -> hardy -> bob) reliably
# delivers multi-fragment bundles (1024B/4096B need multiple CSPCL/SFP
# fragments; 64B/256B don't) when paced, contrasting with
# run_contact_rate_measure.sh's burst-mode (0ms interval) measurement --
# see this folder's README, "CSPCL protocol timeouts under a shaped link",
# for why back-to-back multi-fragment sends trigger a connection-churn
# reliability limit that pacing avoids.
#
# Achieved throughput is timed against vcan0's own `tc -s qdisc show`
# backlog counter, not against apps/receiver's own completion signal: the
# receiver's reported per-packet latency for paced multi-fragment sends has
# been observed to be inconsistent with the real traffic volume seen on
# vcan0 (i.e. it can report a bundle "delivered" before the qdisc has
# actually finished draining that bundle's fragments onto the wire) -- the
# root cause hasn't been isolated yet, and until it is, elapsed time here
# is anchored to the (independently verified, see check_tc_vcan.sh) shaped
# interface itself rather than trusting that signal. Delivered/not
# delivered counts still come from apps/receiver -- only the *timing* used
# for the throughput figure is qdisc-anchored.
#
# Usage: sudo ./test_paced_delivery.sh [output_dir]
# Env overrides: CAN_KBPS=50 TCP_KBPS=100 SIZES="1024 4096" COUNT=10
#                PACE_MARGIN=1.5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SENDER="$REPO_ROOT/apps/sender"
RECEIVER="$REPO_ROOT/apps/receiver"
SHAPE="$SCRIPT_DIR/shape_links.sh"
CEILING="$SCRIPT_DIR/ceiling.py"
CAN_IFACE="vcan0"

OUT_DIR="${1:-$SCRIPT_DIR/results_paced_$(date +%Y%m%d_%H%M%S)}"
PORT=4000
REMOTE=10.0.0.2
CAN_KBPS="${CAN_KBPS:-50}"
TCP_KBPS="${TCP_KBPS:-100}"
read -ra SIZES <<< "${SIZES:-1024 4096}"
COUNT="${COUNT:-10}"
PACE_MARGIN="${PACE_MARGIN:-1.5}"
DRAIN_POLL_S=0.2
DRAIN_TIMEOUT_S=20

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

# Returns vcan0's current qdisc backlog in bytes (0 once fully drained).
qdisc_backlog_bytes() {
    tc -s qdisc show dev "$CAN_IFACE" | awk '/backlog/ {print $2}' | tr -d 'b'
}

# Blocks until vcan0's backlog reads 0 for two consecutive polls (avoids
# treating a momentary dip as "fully drained"), or DRAIN_TIMEOUT_S elapses.
# Echoes "drained" or "timeout" so the caller can tell which happened.
wait_for_drain() {
    local waited=0 zero_streak=0
    while awk "BEGIN{exit !($waited < $DRAIN_TIMEOUT_S)}"; do
        local backlog
        backlog=$(qdisc_backlog_bytes)
        if [[ "$backlog" == "0" ]]; then
            zero_streak=$((zero_streak + 1))
            if [[ $zero_streak -ge 2 ]]; then
                echo "drained"
                return 0
            fi
        else
            zero_streak=0
        fi
        sleep "$DRAIN_POLL_S"
        waited=$(awk "BEGIN{print $waited + $DRAIN_POLL_S}")
    done
    echo "timeout"
    return 1
}

echo "Paced-delivery check: reliability (apps/receiver) + achieved throughput"
echo "(elapsed time anchored to vcan0's own qdisc drain, not apps/receiver's"
echo "completion signal -- see script header) -- results in: $OUT_DIR"
echo ""
printf "%-8s  %-10s  %-9s  %-11s  %-11s  %-11s  %-10s  %-6s\n" \
    "size(B)" "delivered" "pace(ms)" "drain(s)" "achieved" "ceiling" "%%ceiling" "result"
printf "%-8s  %-10s  %-9s  %-11s  %-11s  %-11s  %-10s  %-6s\n" \
    "-------" "---------" "--------" "--------" "kB/s" "kB/s" "-------" "------"

report_rows=()
exit_code=0

for size in "${SIZES[@]}"; do
    logfile="$OUT_DIR/size_${size}_paced.log"

    # Derive the pacing interval from ceiling.py's per-bundle transit-time
    # estimate: give each bundle comfortable margin to fully clear the
    # chain before the next one is sent, instead of firing all COUNT
    # back-to-back (0ms interval), which is what triggers the
    # connection-churn failure this script confirms is avoidable.
    ceiling_csv=$(python3 "$CEILING" --csv --sweep "$size" --can-kbps "$CAN_KBPS" \
        --tcp-kbps "$TCP_KBPS" | tail -1)
    per_bundle_time_s=$(echo "$ceiling_csv" | cut -d',' -f5)
    ceiling_kBps=$(echo "$ceiling_csv" | cut -d',' -f4)
    pace_ms=$(python3 -c "
per_bundle = $per_bundle_time_s
margin = $PACE_MARGIN
floor_ms = 200
print(max(floor_ms, round(per_bundle * margin * 1000)))
")

    # Generous receive timeout: COUNT bundles at pace_ms apart, plus margin
    # for the last one to drain -- same rationale as
    # run_contact_rate_measure.sh's dynamic timeout, just reusing it here
    # for a pass/fail check instead of a throughput figure.
    recv_timeout=$(python3 -c "
import math
pace = $pace_ms / 1000
count = $COUNT
per_bundle = $per_bundle_time_s
print(max(15, math.ceil(count * pace + per_bundle * 5)))
")

    ip netns exec bob_ns "$RECEIVER" $PORT $COUNT > "$logfile" 2>&1 &
    RECV_PID=$!
    sleep 0.3

    t_start=$(date +%s.%N)
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

    # Elapsed time for the throughput figure is anchored to vcan0's own
    # qdisc backlog draining to zero, not to apps/receiver's completion --
    # see script header.
    drain_status=$(wait_for_drain)
    t_end=$(date +%s.%N)
    elapsed_s=$(python3 -c "print($t_end - $t_start)")

    if [[ $delivered -eq $COUNT ]]; then
        result="PASS"
    else
        result="FAIL"
        exit_code=1
    fi

    if [[ $delivered -eq $COUNT && "$drain_status" == "drained" ]]; then
        achieved_kBps=$(python3 -c "print(round(($delivered * $size / $elapsed_s) / 1000, 2))")
        pct=$(python3 -c "print(round(100 * $achieved_kBps / $ceiling_kBps, 1))")
        drain_str=$(python3 -c "print(round($elapsed_s, 2))")
    else
        achieved_kBps="N/A"
        pct="N/A"
        drain_str="timeout"
        if [[ "$drain_status" != "drained" ]]; then
            echo "warning: vcan0 backlog did not drain to zero within ${DRAIN_TIMEOUT_S}s for size=$size -- achieved kB/s not computed" >&2
        fi
    fi

    printf "%-8s  %-10s  %-9s  %-11s  %-11s  %-11s  %-10s  %-6s\n" \
        "$size" "$delivered/$COUNT" "$pace_ms" "$drain_str" "$achieved_kBps" "$ceiling_kBps" "${pct}%" "$result"

    report_rows+=("| $size | $delivered/$COUNT | $pace_ms | $drain_str | $achieved_kBps | $ceiling_kBps | ${pct}% | $result |")
done

report_file="$OUT_DIR/paced_report.md"
{
    echo "# Paced-delivery reliability and throughput"
    echo ""
    echo "CAN hops shaped to ${CAN_KBPS}kbit/s; alice<->unibo shaped to ${TCP_KBPS}kbit/s."
    echo "Elapsed time for achieved kB/s is anchored to vcan0's qdisc backlog"
    echo "draining to zero (verified via \`tc -s qdisc show dev vcan0\`), not to"
    echo "apps/receiver's own completion signal -- see script header for why."
    echo ""
    echo "| payload (B) | delivered | pace (ms) | drain (s) | achieved kB/s | ceiling kB/s | % of ceiling | result |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- |"
    for row in "${report_rows[@]}"; do
        echo "$row"
    done
} > "$report_file"

echo ""
echo "Report: $report_file"

echo ""
echo "Per-size logs saved in: $OUT_DIR"

exit $exit_code
