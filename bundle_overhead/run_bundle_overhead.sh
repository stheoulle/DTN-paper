#!/usr/bin/env bash
# run_bundle_overhead.sh — Section 3 benchmark driver: raw CSP (Arm A) vs
# CSP/BP via CSPCL (Arm B), sweeping bundle granularity N.
#
# Prerequisites:
#   - A SocketCAN interface (real or vcan) that both nodes can reach. Default
#     is a dedicated `vcanbench0` so this can run standalone without the full
#     4-node DEMO.md stack; set CAN_IFACE=vcan0 to co-locate it on the demo
#     bus instead (bench CSP addresses default to 20/21 to avoid colliding
#     with the demo's 1/2/3 — CSP v1.6 addresses are 5 bits wide, 0-31 max).
#   - make (this directory) to build the four binaries.
#   - No root required by this script itself (unlike measure.sh/disrupt.sh,
#     which need root for `ip netns exec`) — only creating the vcan
#     interface needs root, once, ahead of time:
#       sudo modprobe vcan
#       sudo ip link add dev vcanbench0 type vcan
#       sudo ip link set up vcanbench0
#
# Usage: ./run_bundle_overhead.sh [output_dir]
#
# For each N in N_SWEEP, runs:
#   1. Arm B "single-bundle" test:  BUNDLE_COUNT bundles of N units, burst —
#      per-bundle latency + measured cspcl_send_bundle() compute time.
#   2. Arm B "streaming" test:      back-to-back bundles of N units for
#      DURATION_S seconds — sustained throughput.
# Once (N-independent):
#   3. Arm A "single-packet" test:  COUNT raw CSP packets, burst.
#   4. Arm A "streaming" test:      raw CSP packets for DURATION_S seconds.
# Finally prints the analytic memory-overhead table (overhead_table.py) and
# a consolidated summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-/tmp/bundle_overhead_$(date +%Y%m%d_%H%M%S)}"

CAN_IFACE="${CAN_IFACE:-vcanbench0}"
# CSP v1.6 addresses are 5 bits wide (0-31, with 31 reserved for broadcast) —
# this build's CSP_ID_HOST_SIZE=5 silently truncates anything larger, which
# breaks routing. 20/21 stay clear of both that ceiling and the demo's 1/2/3.
TX_ADDR="${TX_ADDR:-20}"
RX_ADDR="${RX_ADDR:-21}"
UNIT_SIZE="${UNIT_SIZE:-32}"          # bytes per CSP-packet-equivalent unit
N_SWEEP=(${N_SWEEP:-1 2 4 8 16 32 64}) # CSP packets aggregated per bundle

BUNDLE_COUNT="${BUNDLE_COUNT:-30}"     # bundles per N in the single-bundle test
STREAM_DURATION_S="${STREAM_DURATION_S:-10}"

RAW_COUNT="${RAW_COUNT:-200}"         # Arm A single-packet test size
RAW_STREAM_DURATION_S="${RAW_STREAM_DURATION_S:-10}"

RECV_TIMEOUT_MS="${RECV_TIMEOUT_MS:-5000}"   # per-bundle/packet timeout while a burst is in flight
QUIET_TIMEOUT_MS="${QUIET_TIMEOUT_MS:-3000}" # streaming: how long to wait after the last one before declaring "done"

SENDER_RAW="$SCRIPT_DIR/csp_raw_sender"
RECEIVER_RAW="$SCRIPT_DIR/csp_raw_receiver"
SENDER_BUNDLE="$SCRIPT_DIR/bundle_sender"
RECEIVER_BUNDLE="$SCRIPT_DIR/bundle_receiver"

if [[ ! -x "$SENDER_RAW" || ! -x "$RECEIVER_RAW" || ! -x "$SENDER_BUNDLE" || ! -x "$RECEIVER_BUNDLE" ]]; then
    echo "Binaries not found — building..." >&2
    make -C "$SCRIPT_DIR"
fi

if ! ip link show "$CAN_IFACE" &>/dev/null; then
    echo "error: $CAN_IFACE not found. Create it first, e.g.:" >&2
    echo "  sudo modprobe vcan && sudo ip link add dev $CAN_IFACE type vcan && sudo ip link set up $CAN_IFACE" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
echo "=== Section 3 benchmark: raw CSP vs CSP/BP(CSPCL) ==="
echo "  iface=$CAN_IFACE  tx_addr=$TX_ADDR  rx_addr=$RX_ADDR  unit_size=${UNIT_SIZE}B"
echo "  N sweep: ${N_SWEEP[*]}"
echo "  Results dir: $OUT_DIR"
echo ""

wait_for_pid() {
    local pid="$1" timeout_s="$2" waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $timeout_s ]]; then
            kill "$pid" 2>/dev/null || true
            break
        fi
    done
}

# ---------------------------------------------------------------------------
# Arm A — raw CSP baseline (N is not meaningful here: always 1 unit/packet)
# ---------------------------------------------------------------------------
echo "--- Arm A: raw CSP, single-packet burst (count=$RAW_COUNT) ---"
rawlog="$OUT_DIR/arm_a_burst.log"
"$RECEIVER_RAW" "$RX_ADDR" "$CAN_IFACE" "$RAW_COUNT" 20 10000 "$RECV_TIMEOUT_MS" > "$rawlog" 2>&1 &
recv_pid=$!
sleep 0.3
"$SENDER_RAW" "$TX_ADDR" "$RX_ADDR" "$CAN_IFACE" "$RAW_COUNT" "$UNIT_SIZE" 0 20 >> "$rawlog" 2>&1
wait_for_pid "$recv_pid" 30
echo "  log: $rawlog"
grep -E '^---|received|latency|throughput' "$rawlog" || true
echo ""

echo "--- Arm A: raw CSP, streaming (duration=${RAW_STREAM_DURATION_S}s) ---"
rawstreamlog="$OUT_DIR/arm_a_stream.log"
"$RECEIVER_RAW" "$RX_ADDR" "$CAN_IFACE" 0 20 10000 "$QUIET_TIMEOUT_MS" > "$rawstreamlog" 2>&1 &
recv_pid=$!
sleep 0.3
"$SENDER_RAW" "$TX_ADDR" "$RX_ADDR" "$CAN_IFACE" 0 "$UNIT_SIZE" "$RAW_STREAM_DURATION_S" 20 >> "$rawstreamlog" 2>&1
wait_for_pid "$recv_pid" $((RAW_STREAM_DURATION_S + 15))
echo "  log: $rawstreamlog"
grep -E '^---|received|latency|throughput' "$rawstreamlog" || true
echo ""

# ---------------------------------------------------------------------------
# Arm B — CSP/BP via CSPCL, sweeping N
# ---------------------------------------------------------------------------
printf "%-4s  %-10s  %-10s  %-10s  %-14s  %-10s  %-14s\n" \
    "N" "bndl/sec" "units/sec" "kB/s" "mean_lat(ms)" "delivered" "mean_send(ms)"
printf "%-4s  %-10s  %-10s  %-10s  %-14s  %-10s  %-14s\n" \
    "--" "--------" "---------" "----" "------------" "---------" "-------------"

for n in "${N_SWEEP[@]}"; do
    echo "--- Arm B: CSP/BP(CSPCL), N=$n, single-bundle burst (count=$BUNDLE_COUNT) ---" >&2
    burstlog="$OUT_DIR/arm_b_burst_N${n}.log"
    "$RECEIVER_BUNDLE" "$RX_ADDR" "$CAN_IFACE" "$BUNDLE_COUNT" "$RECV_TIMEOUT_MS" > "$burstlog" 2>&1 &
    recv_pid=$!
    sleep 0.3
    "$SENDER_BUNDLE" "$TX_ADDR" "$RX_ADDR" "$CAN_IFACE" "$n" "$UNIT_SIZE" "$BUNDLE_COUNT" 0 >> "$burstlog" 2>&1
    wait_for_pid "$recv_pid" 60

    mean_send=$(grep '^SUMMARY' "$burstlog" | grep -oP 'mean_send_ms=\K[0-9.]+' || echo "N/A")
    delivered=$(grep -c '^RECV_BUNDLE' "$burstlog" || true)
    mean_lat=$(grep 'mean=' "$burstlog" | grep -oP 'mean=\K[0-9.]+' || echo "N/A")
    bps=$(grep 'bundles/sec' "$burstlog" | grep -oP '\K[0-9.]+(?= bundles/sec)' || echo "N/A")
    ups=$(grep 'units/sec-equivalent' "$burstlog" | grep -oP '\K[0-9.]+(?= units/sec-equivalent)' || echo "N/A")
    kbps=$(grep 'kB/s' "$burstlog" | grep -oP '\K[0-9.]+(?= kB/s)' || echo "N/A")

    printf "%-4s  %-10s  %-10s  %-10s  %-14s  %-10s  %-14s\n" \
        "$n" "$bps" "$ups" "$kbps" "$mean_lat" "$delivered/$BUNDLE_COUNT" "$mean_send"

    echo "--- Arm B: CSP/BP(CSPCL), N=$n, streaming (duration=${STREAM_DURATION_S}s) ---" >&2
    streamlog="$OUT_DIR/arm_b_stream_N${n}.log"
    "$RECEIVER_BUNDLE" "$RX_ADDR" "$CAN_IFACE" 0 "$QUIET_TIMEOUT_MS" > "$streamlog" 2>&1 &
    recv_pid=$!
    sleep 0.3
    "$SENDER_BUNDLE" "$TX_ADDR" "$RX_ADDR" "$CAN_IFACE" "$n" "$UNIT_SIZE" 0 "$STREAM_DURATION_S" >> "$streamlog" 2>&1
    wait_for_pid "$recv_pid" $((STREAM_DURATION_S + 15))
done

echo ""
echo "=== Analytic memory overhead (Section 3, item: memory) ==="
python3 "$SCRIPT_DIR/overhead_table.py" --unit-size "$UNIT_SIZE" --sweep "${N_SWEEP[@]}"

echo ""
echo "Per-run logs saved in: $OUT_DIR"
echo "Single-bundle burst logs: arm_b_burst_N<N>.log   (per-bundle latency + measured cspcl_send_bundle() compute time)"
echo "Streaming logs:           arm_b_stream_N<N>.log  (sustained throughput)"
echo "Arm A baselines:          arm_a_burst.log, arm_a_stream.log"
