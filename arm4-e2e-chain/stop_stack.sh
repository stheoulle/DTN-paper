#!/usr/bin/env bash
# Tears down everything start_stack.sh started. Safe to run even if some
# processes already died (kill errors are ignored).
#
# Usage: sudo bash stop_stack.sh [OUT_DIR]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/stack_logs}"
PID_DIR="$OUT_DIR/pids"

if [[ -d "$PID_DIR" ]]; then
    for pidfile in "$PID_DIR"/*.pid; do
        [[ -f "$pidfile" ]] || continue
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
    done
fi

# unibo-bp core and TCPCL CLA are started via --daemon and don't leave a
# tracked PID here; sweep by process name like DEMO.md's own cleanup does.
pkill -f "unibo-bp start" 2>/dev/null || true
pkill -f "unibo-bp-tcpcl" 2>/dev/null || true

sleep 1
rm -f /tmp/alice.aap2.socket /tmp/alice.socket /tmp/bob.aap2.socket /tmp/bob.socket
rm -rf /tmp/unibo-node1

echo "Stack stopped. (vcan0/alice_ns/bob_ns left up -- rerun setup_root.sh's"
echo "teardown manually if you also want those removed:"
echo "  sudo ip link del vcan0; sudo ip netns del alice_ns; sudo ip netns del bob_ns)"
