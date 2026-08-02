#!/usr/bin/env bash
# Starts the two uD3TN nodes shared by Arm 2 and Arm 3: node-a (CSP addr 1)
# and node-b (CSP addr 2), directly linked over vcanlayer0 via the CSPCL CLA,
# with a static FIB entry each way (no A-SABR needed for a direct 2-node
# link — that's deliberately out of scope for this per-layer overhead test).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UD3TN_BIN="$REPO_ROOT/ud3tn/build/posix/ud3tn"
IFACE=vcanlayer0

if [[ ! -x "$UD3TN_BIN" ]]; then
    echo "error: $UD3TN_BIN not found — build uD3TN first (see repo README)" >&2
    exit 1
fi

if ! ip link show "$IFACE" &>/dev/null; then
    echo "error: $IFACE not found — run 'sudo bash setup_root.sh' first" >&2
    exit 1
fi

rm -f /tmp/layer-node-a.aap2.socket /tmp/layer-node-a.socket
rm -f /tmp/layer-node-b.aap2.socket /tmp/layer-node-b.socket

LOG_DIR="$SCRIPT_DIR/results"
mkdir -p "$LOG_DIR"

"$UD3TN_BIN" \
    -e dtn://node-a.dtn/ \
    -S /tmp/layer-node-a.aap2.socket \
    -s /tmp/layer-node-a.socket \
    -c "csp:1,10,can:${IFACE}" > "$LOG_DIR/node-a-daemon.log" 2>&1 &
echo "node-a pid=$! (log: $LOG_DIR/node-a-daemon.log)"

"$UD3TN_BIN" \
    -e dtn://node-b.dtn/ \
    -S /tmp/layer-node-b.aap2.socket \
    -s /tmp/layer-node-b.socket \
    -c "csp:2,10,can:${IFACE}" > "$LOG_DIR/node-b-daemon.log" 2>&1 &
echo "node-b pid=$! (log: $LOG_DIR/node-b-daemon.log)"

sleep 1

# When this script runs under sudo (e.g. for symmetry with run_arm3.sh),
# uD3TN creates these AAP2 sockets as root. run_arm2.sh connects to them as
# your regular user, so open the permissions regardless of which privilege
# level started the nodes.
for sock in /tmp/layer-node-a.aap2.socket /tmp/layer-node-a.socket \
            /tmp/layer-node-b.aap2.socket /tmp/layer-node-b.socket; do
    for _ in $(seq 1 20); do
        [[ -S "$sock" ]] && break
        sleep 0.2
    done
    chmod 666 "$sock" 2>/dev/null || true
done

source "$REPO_ROOT/.venv/bin/activate"

# FIB layer: tells each node's CSP CLA how to reach the peer (this alone was
# not sufficient — see below).
aap2-configure-link --socket /tmp/layer-node-a.aap2.socket dtn://node-b.dtn/ csp:2
aap2-configure-link --socket /tmp/layer-node-b.aap2.socket dtn://node-a.dtn/ csp:1

# Routing layer: without -d/--external-dispatch, uD3TN uses its internal
# "compat" router, which is a *separate* component from the FIB above — it
# needs an actual node+contact registered in its own routing table, or
# router_get_first_route() finds zero contacts and bundles are silently
# dropped (only logged at DEBUG level). -s <start_offset> <duration_s>
# <bitrate_bps>: starts now, lasts 24h, well above what these small test
# bundles need.
aap2-config --socket /tmp/layer-node-a.aap2.socket dtn://node-b.dtn/ csp:2 -s 0 86400 1200000
aap2-config --socket /tmp/layer-node-b.aap2.socket dtn://node-a.dtn/ csp:1 -s 0 86400 1200000

echo "node-a and node-b up, FIB entries and contacts configured."
