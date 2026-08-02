#!/usr/bin/env bash
# Brings up the full Arm 3 stack (CAN/CSP/BP/CSP via Charon) and leaves it
# running, mirroring DEMO.md's phased "start the stack, then send traffic"
# structure (Phases 1-3) instead of run_arm3.sh's start-sweep-teardown in one
# shot. Use this to poke at the stack interactively -- manual apps/sender +
# apps/receiver runs, aap2_send/aap2_receive, candump vcanlayer0, etc. --
# without paying uD3TN/Charon startup cost on every invocation.
#
# Brings up, in order (see DEMO.md Phases 1-3 for the full-demo equivalent):
#   1. vcanlayer0 + layer_a_ns/layer_b_ns   (setup_root.sh)
#   2. node-a/node-b uD3TN + FIB/routes     (start_nodes.sh)
#   3. Charon alice/bob in their netns      (same config run_arm3.sh uses)
#
# Charon is started detached (disowned) so it survives this script exiting.
# Must be run as root throughout, same as run_arm3.sh (TUN + netns).
#
# Usage: sudo bash up_arm3.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (sudo bash up_arm3.sh) -- needs TUN + netns" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHARON_BIN="$REPO_ROOT/charon/build/charon"

if [[ ! -x "$CHARON_BIN" ]]; then
    echo "error: $CHARON_BIN not found -- build charon first (see repo README)" >&2
    exit 1
fi

echo "=== [1/3] vcanlayer0 + netns ==="
bash "$SCRIPT_DIR/setup_root.sh"

echo ""
echo "=== [2/3] node-a / node-b (uD3TN) ==="
if pgrep -f "build/posix/ud3tn -e dtn://node-a.dtn" &>/dev/null; then
    echo "node-a already running, skipping"
else
    bash "$SCRIPT_DIR/start_nodes.sh"
fi

echo ""
echo "=== [3/3] Charon (node-a, node-b) ==="
mkdir -p "$SCRIPT_DIR/results"
if pgrep -f "charon/build/charon .*layer-overhead" &>/dev/null; then
    echo "Charon already running, skipping"
else
    ip netns exec layer_a_ns env CHARON_SECRET=layer_bench_secret \
        "$CHARON_BIN" "$SCRIPT_DIR/configs/node-a-charon.conf" \
        > "$SCRIPT_DIR/results/charon-a.log" 2>&1 &
    disown

    ip netns exec layer_b_ns env CHARON_SECRET=layer_bench_secret \
        "$CHARON_BIN" "$SCRIPT_DIR/configs/node-b-charon.conf" \
        > "$SCRIPT_DIR/results/charon-b.log" 2>&1 &
    disown

    sleep 1
fi

echo ""
echo "Arm 3 stack is up:"
echo "  node-a AAP2   /tmp/layer-node-a.aap2.socket"
echo "  node-b AAP2   /tmp/layer-node-b.aap2.socket"
echo "  Charon alice  layer_a_ns, layertun0 10.1.0.1"
echo "  Charon bob    layer_b_ns, layertun1 10.1.0.2"
echo ""
echo "Manual test (same shape as DEMO.md Phase 4):"
echo "  sudo ip netns exec layer_b_ns $REPO_ROOT/apps/receiver 4000"
echo "  sudo ip netns exec layer_a_ns $REPO_ROOT/apps/sender 10.1.0.2 4000"
echo ""
echo "To run the automated sweep instead, tear this stack down first --"
echo "run_arm3.sh starts its own Charon pair on the same TUN devices/sockets:"
echo "  sudo bash teardown.sh && sudo bash run_arm3.sh"
