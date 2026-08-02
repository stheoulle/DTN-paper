#!/usr/bin/env bash
# Sweeps the full 4-node chain (alice -> unibo -> hardy -> bob, tunneled
# through Charon at both ends) at the paper's *realistic* CSP telemetry/
# command payload sizes, REPS independent repetitions each, two campaigns
# per size exactly like layer-overhead/'s arm2/arm3:
#   - throughput_results: COUNT=10 packet burst per rep (wall-clock
#     bytes/s, matching apps/measure.sh's original method)
#   - latency_results: COUNT=1 packet per rep, decoupled from any
#     within-burst queuing, for a clean per-bundle latency distribution
#
# Links are shaped to the contact plan's modeled rates via
# contact_rate/shape_links.sh (reused as-is, not reimplemented -- it was
# already built and validated for this exact purpose, see
# contact_rate/README.md and check_tc_vcan.sh) before the sweep starts,
# and always un-shaped on exit. Without this, achieved throughput is
# bound only by software overhead on an unconstrained vcan0/loopback link
# and comes out *faster* than the modeled ceiling, which answers a
# different question than reviewer 2 asked ("throughput vs modeled 50/100
# kbps rates" implies the rates are actually enforced).
#
# Requires start_stack.sh to already be running (this script does NOT
# start/stop the ten DTN processes -- restarting all of them per rep
# would be both unnecessary, since each message is already an independent
# trial, and impractical at N=100+).
#
# SIZES default is 64/256 B only, not the full 64/256/1024/4096 sweep
# used elsewhere in this paper's other benchmarks. Those two sizes are
# what CSP telemetry/command traffic on this project's target CubeSats
# actually looks like; 1024/4096 B were never realistic message sizes
# here and were only ever used elsewhere (layer-overhead/, contact_rate/)
# to stress-test the connection pool -- a different question, already
# answered by the pool-mutex finding in Section IV-D, and one this
# section deliberately does not re-litigate at the 4-hop level. This
# also sidesteps a real practical cost: under genuine 50/100kbps shaping,
# 1024/4096 B bursts collapse to ~3/10 and ~1/10 delivered (see
# contact_rate/README.md's "Connection churn under back-to-back
# multi-fragment bundles" -- uD3TN's CSP CLA tearing down its
# opportunistic link mid-transfer, not a timeout, not fixable from this
# harness), which would push REPS=100 at 4096B alone to ~4.6h of mostly
# waiting out timeouts. Override SIZES to include them anyway if wanted
# for engineering purposes, but budget wall-clock time accordingly.
#
# Usage: sudo bash run_arm4.sh [OUT_DIR] [REPS]
#   OUT_DIR default: ./results
#   REPS    default: 100
# Env overrides: CAN_KBPS=50 TCP_KBPS=100 SIZES="64 256" (must match what
#   summarize_arm4.py is later pointed at, since ceiling.py needs the same
#   rates to compare against)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (ip netns exec / tc require it)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SENDER="$DTN_ROOT/apps/sender"
RECEIVER="$DTN_ROOT/apps/receiver"
SHAPE="$DTN_ROOT/contact_rate/shape_links.sh"
CEILING="$DTN_ROOT/contact_rate/ceiling.py"
OUT_DIR="${1:-$SCRIPT_DIR/results}"
REPS="${2:-100}"
PORT=4000
REMOTE=10.0.0.2
CAN_KBPS="${CAN_KBPS:-50}"
TCP_KBPS="${TCP_KBPS:-100}"

read -ra SIZES <<< "${SIZES:-64 256}"

if [[ ! -x "$SENDER" || ! -x "$RECEIVER" ]]; then
    echo "error: sender/receiver not found — run: make -C apps" >&2
    exit 1
fi
if [[ ! -x "$SHAPE" ]]; then
    echo "error: $SHAPE not found or not executable" >&2
    exit 1
fi
for ns in alice_ns bob_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        echo "error: netns $ns not found — run setup_root.sh first" >&2
        exit 1
    fi
done
for sock in /tmp/alice.aap2.socket /tmp/bob.aap2.socket; do
    if [[ ! -S "$sock" ]]; then
        echo "error: $sock not found — run start_stack.sh first" >&2
        exit 1
    fi
done

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# Same timeout-scaling logic as contact_rate/run_contact_rate_measure.sh:
# ceiling.py's own per-bundle time estimate x COUNT x safety margin,
# rather than a fixed value that would either be far too short at 4096B
# or far too long (wasted wall-clock) at 64B.
size_timeout() {
    local size="$1" count="$2" margin="$3"
    local per_bundle_time_s
    per_bundle_time_s=$(python3 "$CEILING" --csv --sweep "$size" \
        --can-kbps "$CAN_KBPS" --tcp-kbps "$TCP_KBPS" | tail -1 | cut -d',' -f5)
    python3 -c "
import math
per_bundle = $per_bundle_time_s
count = $count
margin = $margin
print(max(15, math.ceil(per_bundle * count * margin)))
"
}

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

run_campaign() {
    local campaign="$1" count="$2" margin="$3"

    for size in "${SIZES[@]}"; do
        local size_dir="$OUT_DIR/${campaign}/size_${size}"
        mkdir -p "$size_dir"
        local timeout_s
        timeout_s=$(size_timeout "$size" "$count" "$margin")
        echo "-- ${campaign} size=${size}B (count=${count}, timeout=${timeout_s}s, ${REPS} reps) --"

        for rep in $(seq -w 1 "$REPS"); do
            local log="$size_dir/rep_${rep}.log"
            local timing="$size_dir/rep_${rep}.timing"

            timeout "${timeout_s}s" \
                ip netns exec bob_ns "$RECEIVER" "$PORT" "$count" > "$log" 2>&1 &
            local recv_pid=$!
            sleep 0.3

            local t_start
            t_start=$(date +%s%N)
            timeout "${timeout_s}s" \
                ip netns exec alice_ns "$SENDER" "$REMOTE" "$PORT" "$count" "$size" 0 \
                >> "$log" 2>&1 || true

            wait "$recv_pid" || echo "  rep $rep: receiver exited non-zero — check $log"
            local t_end
            t_end=$(date +%s%N)
            echo "$t_start $t_end" > "$timing"

            local delivered
            delivered=$(grep -c '^RECV ' "$log" || true)
            echo "  rep $rep: $delivered/$count delivered"
        done
    done
}

echo "=== Arm 4: full 4-node chain, throughput campaign (shaped) ==="
run_campaign "throughput_results" 10 5.0

# No separate single-packet latency campaign: confirmed against real data
# that an isolated packet sent after the idle gap between reps always
# finds shape_links.sh's tbf token bucket freshly refilled (burst=64,
# deliberately tiny, refills in ~10ms at 50kbit/s) and gets the same free
# ride as any burst's first packet -- an isolated single-packet rep
# measured 9.4ms, matching a same-size burst's first packet (8.0ms)
# almost exactly, while that burst's later packets (once the token
# bucket was drained) cost ~101ms each, the real shaped rate. Mean
# latency is derived from the throughput campaign's own within-burst
# per-packet timestamps instead (see summarize_arm4.py) -- the same
# convention the paper's existing, already-reviewed Table D used
# (apps/measure.sh, COUNT=10 burst), just averaged across REPS
# independent bursts here instead of one.

echo ""
echo "Arm 4 done. Results under: $OUT_DIR"
echo "Run 'python3 $SCRIPT_DIR/summarize_arm4.py $OUT_DIR' to build the comparison table."
