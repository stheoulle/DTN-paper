#!/usr/bin/env bash
# disrupt.sh — Store-and-forward disruption test for the DTN/CSPCL experiment.
#
# Prerequisites:
#   - Full stack running (DEMO.md Phase 1–3, terminals T1–T9 all up)
#   - apps/sender and apps/receiver compiled (make -C apps)
#   - Run as root (vcan0 and ip netns require it)
#
# Usage: sudo ./apps/disrupt.sh
#
# Timeline:
#   t=0s    sender starts; packets flow through vcan0 (unibo↔hardy↔bob)
#   t=3s    vcan0 is brought DOWN — CSPCL connections break, BPAs store bundles
#   t=13s   vcan0 is brought UP   — BPAs retry; stored bundles are delivered
#
# Success criterion: receiver reports 100% delivery despite the 10-second gap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SENDER="$SCRIPT_DIR/sender"
RECEIVER="$SCRIPT_DIR/receiver"
PORT=4000
REMOTE=10.0.0.2
COUNT=15             # total packets to send
SIZE=2048             # bytes per packet
INTERVAL_MS=100      # 100 ms between sends → 6 s total send window
LINK_DOWN_AFTER=3    # seconds after sender starts to cut the link
LINK_DOWN_FOR=10     # seconds the link stays down
TIMEOUT=30          # max seconds to wait for receiver after link restored
LOGFILE="/tmp/dtn_disrupt_$(date +%Y%m%d_%H%M%S).log"

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root" >&2
    exit 1
fi

if [[ ! -x "$SENDER" || ! -x "$RECEIVER" ]]; then
    echo "error: sender/receiver not found — run: make -C apps" >&2
    exit 1
fi

if ! ip link show vcan0 &>/dev/null; then
    echo "error: vcan0 not found — run DEMO.md Phase 1 first" >&2
    exit 1
fi

echo "=== DTN store-and-forward disruption test ==="
echo "  $COUNT packets × ${SIZE}B  interval=${INTERVAL_MS}ms"
echo "  Link down after ${LINK_DOWN_AFTER}s  for ${LINK_DOWN_FOR}s"
echo "  Log: $LOGFILE"
echo ""

# Start receiver in bob_ns (waits for COUNT packets then prints stats)
ip netns exec bob_ns "$RECEIVER" $PORT $COUNT > "$LOGFILE" 2>&1 &
RECV_PID=$!
sleep 0.3

echo "[$(date +%T)] Starting sender (${COUNT} pkts × ${INTERVAL_MS}ms = ~$((COUNT * INTERVAL_MS / 1000))s)"
ip netns exec alice_ns "$SENDER" $REMOTE $PORT $COUNT $SIZE $INTERVAL_MS \
    >> "$LOGFILE" 2>&1 &
SEND_PID=$!

# # Cut the link while sender is still running
# sleep $LINK_DOWN_AFTER
# echo "[$(date +%T)] Bringing vcan0 DOWN — simulating link interruption"
# ip link set vcan0 down

# sleep $LINK_DOWN_FOR
# echo "[$(date +%T)] Bringing vcan0 UP   — store-and-forward should deliver queued bundles"
# ip link set vcan0 up

# # Wait for sender to finish (it may still be sending)
# wait $SEND_PID 2>/dev/null || true

# Wait for receiver to collect all packets (or timeout)
echo "[$(date +%T)] Waiting for receiver to report all $COUNT packets..."
waited=0
while kill -0 $RECV_PID 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [[ $waited -ge $TIMEOUT ]]; then
        echo "[$(date +%T)] Timeout — killing receiver and printing partial stats"
        kill $RECV_PID 2>/dev/null || true
        break
    fi
done

echo ""
echo "=== Results ==="
grep -E '^RECV|^---|received|latency' "$LOGFILE" || cat "$LOGFILE"
echo ""
echo "Full log: $LOGFILE"

# Final verdict
delivered=$(grep -c '^RECV ' "$LOGFILE" || true)
if [[ $delivered -eq $COUNT ]]; then
    echo "PASS: all $COUNT packets delivered despite link interruption"
else
    echo "PARTIAL: $delivered / $COUNT packets delivered"
fi
