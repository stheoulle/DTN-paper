#!/usr/bin/env bash
# measure.sh — Latency and throughput sweep over the full 4-hop DTN chain.
#
# Prerequisites:
#   - Full stack running (DEMO.md Phase 1–3, terminals T1–T9 all up)
#   - apps/sender and apps/receiver compiled (make -C apps)
#   - Run as root (ip netns exec requires it)
#
# Usage: sudo ./apps/measure.sh [output_dir]
#
# For each payload size in SIZES the script:
#   1. Starts receiver in bob_ns
#   2. Sends COUNT packets of that size in burst mode from alice_ns
#   3. Waits for receiver to report all COUNT packets (or TIMEOUT seconds)
#   4. Saves per-packet lines and summary to output_dir/size_<N>.log
#
# Final output: a table of mean latency and throughput per payload size.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SENDER="$SCRIPT_DIR/sender"
RECEIVER="$SCRIPT_DIR/receiver"
OUT_DIR="${1:-/tmp/dtn_measure_$(date +%Y%m%d_%H%M%S)}"
PORT=4000
REMOTE=10.0.0.2
COUNT=50             # packets per run
TIMEOUT=120          # seconds to wait for receiver before giving up
SIZES=(64 256 1024 4096)

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (ip netns exec requires it)" >&2
    exit 1
fi

if [[ ! -x "$SENDER" || ! -x "$RECEIVER" ]]; then
    echo "error: sender/receiver not found — run: make -C apps" >&2
    exit 1
fi

for ns in alice_ns bob_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        echo "error: network namespace $ns not found — run DEMO.md Phase 1 first" >&2
        exit 1
    fi
done

mkdir -p "$OUT_DIR"
echo "Results will be written to: $OUT_DIR"
echo ""
printf "%-10s  %-12s  %-12s  %-12s  %-12s  %-14s\n" \
    "size(B)" "delivered" "min(ms)" "mean(ms)" "max(ms)" "throughput"
printf "%-10s  %-12s  %-12s  %-12s  %-12s  %-14s\n" \
    "-------" "---------" "-------" "--------" "-------" "----------"

for size in "${SIZES[@]}"; do
    logfile="$OUT_DIR/size_${size}.log"

    # Start receiver in bob_ns; it exits automatically after COUNT packets
    ip netns exec bob_ns "$RECEIVER" $PORT $COUNT > "$logfile" 2>&1 &
    RECV_PID=$!

    # Give receiver time to bind before the first packet arrives
    sleep 0.3

    # Burst-send COUNT packets from alice_ns (interval_ms=0)
    t_start=$(date +%s%N)
    ip netns exec alice_ns "$SENDER" $REMOTE $PORT $COUNT $size 0 \
        >> "$logfile" 2>&1
    t_send_done=$(date +%s%N)

    # Wait for receiver (it self-exits after COUNT; kill it on timeout)
    waited=0
    while kill -0 $RECV_PID 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [[ $waited -ge $TIMEOUT ]]; then
            kill $RECV_PID 2>/dev/null || true
            break
        fi
    done
    t_end=$(date +%s%N)

    # Parse summary from logfile
    delivered=$(grep -c '^RECV ' "$logfile" || true)
    min_ms=$(grep 'min=' "$logfile" | grep -oP 'min=\K[0-9.]+' || echo "N/A")
    mean_ms=$(grep 'mean=' "$logfile" | grep -oP 'mean=\K[0-9.]+' || echo "N/A")
    max_ms=$(grep 'max=' "$logfile" | grep -oP 'max=\K[0-9.]+' || echo "N/A")

    # Throughput: total bytes delivered / elapsed seconds (send start → last recv)
    elapsed_ns=$((t_end - t_start))
    elapsed_s=$(echo "scale=3; $elapsed_ns / 1000000000" | bc)
    total_bytes=$((delivered * size))
    if [[ $elapsed_ns -gt 0 && $delivered -gt 0 ]]; then
        bps=$(echo "scale=1; $total_bytes / $elapsed_s" | bc)
        kbps=$(echo "scale=1; $bps / 1000" | bc)
        throughput="${kbps} kB/s"
    else
        throughput="N/A"
    fi

    printf "%-10s  %-12s  %-12s  %-12s  %-12s  %-14s\n" \
        "$size" "$delivered/$COUNT" "$min_ms" "$mean_ms" "$max_ms" "$throughput"
done

echo ""
echo "Per-packet logs saved in: $OUT_DIR"
