#!/usr/bin/env bash
# Brings up the full 4-node chain (DEMO.md Phase 3, T1-T9) exactly once,
# then run_arm4.sh drives many independent send/receive trials against
# this single long-lived stack -- restarting all ten processes per trial
# (as DEMO.md's manual procedure would imply) is neither necessary (each
# trial is already an independent message) nor practical at N=100+ reps.
#
# Requires setup_root.sh to have been run first (vcan0, alice_ns, bob_ns).
# Requires root (for the two Charon instances, run inside their netns).
#
# Logs go to $OUT_DIR (default: ./stack_logs); PIDs to $OUT_DIR/pids so
# stop_stack.sh can clean up.
#
# Usage: sudo bash start_stack.sh [OUT_DIR]

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root -- Charon needs it for TUN, and this script" >&2
    echo "       starts every component itself (no need to run parts unprivileged)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DTN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/stack_logs}"
PID_DIR="$OUT_DIR/pids"

mkdir -p "$OUT_DIR" "$PID_DIR"

for ns in alice_ns bob_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        echo "error: netns $ns not found -- run setup_root.sh first" >&2
        exit 1
    fi
done
if ! ip link show vcan0 &>/dev/null; then
    echo "error: vcan0 not found -- run setup_root.sh first" >&2
    exit 1
fi

wait_for_socket() {
    local sock="$1" timeout="${2:-15}" waited=0
    while [[ ! -S "$sock" ]]; do
        sleep 0.5
        waited=$((waited + 1))
        if (( waited * 5 >= timeout * 10 )); then
            echo "error: timed out waiting for $sock" >&2
            return 1
        fi
    done
}

echo "=== T1: alice uD3TN (BDM mode) ==="
cd "$DTN_ROOT/ud3tn"
./build/posix/ud3tn \
    -e dtn://alice.dtn/ \
    -S /tmp/alice.aap2.socket \
    -s /tmp/alice.socket \
    -c "tcpclv3:*,4224" \
    -d > "$OUT_DIR/alice_ud3tn.log" 2>&1 &
echo $! > "$PID_DIR/alice_ud3tn.pid"
wait_for_socket /tmp/alice.aap2.socket

echo "=== T2: alice A-SABR BDM ==="
cd "$DTN_ROOT"
source .venv/bin/activate
cd asabr_bdm
python main.py \
    ../demo/alice.cp \
    ../demo/alice-eid-map.json \
    --socket /tmp/alice.aap2.socket \
    -vv > "$OUT_DIR/alice_bdm.log" 2>&1 &
echo $! > "$PID_DIR/alice_bdm.pid"
cd "$DTN_ROOT"

echo "=== T3: unibo-bp core ==="
export UNIBO_BP_BIN="$DTN_ROOT/unibo-dtn/unibo-bp/build/Unibo-BP/bin"
rm -rf /tmp/unibo-node1
mkdir -p /tmp/unibo-node1
cd /tmp/unibo-node1
"$UNIBO_BP_BIN/unibo-bp" start \
    --set-storage-size 50000000 \
    --dtn-admin dtn://unibo.dtn/ \
    --ipn-admin ipn:1.0 \
    --daemon > "$OUT_DIR/unibo_core.log" 2>&1
sleep 1

echo "-- unibo-bp routing/contact setup --"
REFERENCE_TIME=$("$UNIBO_BP_BIN/unibo-bp-utility" --get-utc-time +0)

"$UNIBO_BP_BIN/unibo-bp-admin" region home --register-node ipn:1.0
"$UNIBO_BP_BIN/unibo-bp-admin" region home --register-node ipn:2.0

"$UNIBO_BP_BIN/unibo-bp-admin" range add \
    --start-time +0 --end-time +86400 \
    --sender ipn:1.0 --receiver ipn:2.0 --owlt 0 \
    --reference-time "$REFERENCE_TIME"
"$UNIBO_BP_BIN/unibo-bp-admin" range add \
    --start-time +0 --end-time +86400 \
    --sender ipn:2.0 --receiver ipn:1.0 --owlt 0 \
    --reference-time "$REFERENCE_TIME"

"$UNIBO_BP_BIN/unibo-bp-admin" contact add \
    --start-time +0 --end-time +86400 \
    --sender ipn:1.0 --receiver ipn:2.0 \
    --xmit-rate 50000 --reference-time "$REFERENCE_TIME"
"$UNIBO_BP_BIN/unibo-bp-admin" contact add \
    --start-time +0 --end-time +86400 \
    --sender ipn:2.0 --receiver ipn:1.0 \
    --xmit-rate 50000 --reference-time "$REFERENCE_TIME"

"$UNIBO_BP_BIN/unibo-bp-admin" routing static add \
    --destination dtn://hardy.dtn/* --gateway ipn:2.0
"$UNIBO_BP_BIN/unibo-bp-admin" routing static add \
    --destination dtn://bob.dtn/* --gateway ipn:2.0

echo "=== T3b: unibo TCPCLv3 CLA (toward alice) ==="
"$UNIBO_BP_BIN/unibo-bp-tcpcl" --daemon > "$OUT_DIR/unibo_tcpcl.log" 2>&1
sleep 1
"$UNIBO_BP_BIN/unibo-bp-admin" tcpcl induct add --port 4225

echo "=== T5: Hardy BPA server (must be up before T4) ==="
cd "$DTN_ROOT"
"$DTN_ROOT/hardy/target/release/hardy-bpa-server" \
    --config "$DTN_ROOT/demo/hardy.yaml" > "$OUT_DIR/hardy.log" 2>&1 &
echo $! > "$PID_DIR/hardy.pid"
sleep 2

echo "=== T4: unibo CSPCL daemon (CAN bridge toward Hardy) ==="
cd "$DTN_ROOT/cspcl/unibo-integration"
if [[ ! -x build/unibo-bp-cspcl ]]; then
    export UNIBO_BP_LIB="$DTN_ROOT/unibo-dtn/unibo-bp/build/Unibo-BP/lib"
    export LIBCSP_BUILD="$DTN_ROOT/libcsp/build"
    mkdir -p build
    gcc -O2 -Wall -Wextra \
        src/cspcl_daemon.c ../src/cspcl.c \
        -o build/unibo-bp-cspcl \
        -I../src \
        -I"$DTN_ROOT/unibo-dtn/unibo-bp/include" \
        -I"$DTN_ROOT/libcsp/include" \
        -I"$DTN_ROOT/libcsp/build/include" \
        -L"$UNIBO_BP_LIB" \
        -Wl,-rpath,"$UNIBO_BP_LIB" \
        -lunibo-bp-api \
        "$LIBCSP_BUILD/libcsp.a" \
        -lzmq -lpthread -lm \
        -lsocketcan
fi
./build/unibo-bp-cspcl 1 10 can 2001 /tmp/unibo-node1 > "$OUT_DIR/unibo_cspcl.log" 2>&1 &
echo $! > "$PID_DIR/unibo_cspcl.pid"
sleep 1

echo "=== T6: bob uD3TN with CSPCL (BDM mode) ==="
cd "$DTN_ROOT/ud3tn"
./build/posix/ud3tn \
    -e dtn://bob.dtn/ \
    -S /tmp/bob.aap2.socket \
    -s /tmp/bob.socket \
    -c "csp:3,10,can" \
    -d > "$OUT_DIR/bob_ud3tn.log" 2>&1 &
echo $! > "$PID_DIR/bob_ud3tn.pid"
wait_for_socket /tmp/bob.aap2.socket

echo "=== T7: bob A-SABR BDM ==="
cd "$DTN_ROOT"
source .venv/bin/activate
cd asabr_bdm
python main.py \
    ../demo/alice.cp \
    ../demo/bob-eid-map.json \
    --socket /tmp/bob.aap2.socket \
    -vv > "$OUT_DIR/bob_bdm.log" 2>&1 &
echo $! > "$PID_DIR/bob_bdm.pid"
cd "$DTN_ROOT"

echo "=== T8: Charon alice (netns alice_ns, root) ==="
ip netns exec alice_ns \
    env CHARON_SECRET=demo_secret \
    "$DTN_ROOT/charon/build/charon" "$DTN_ROOT/demo/charon-alice.conf" \
    > "$OUT_DIR/charon_alice.log" 2>&1 &
echo $! > "$PID_DIR/charon_alice.pid"

echo "=== T9: Charon bob (netns bob_ns, root) ==="
ip netns exec bob_ns \
    env CHARON_SECRET=demo_secret \
    "$DTN_ROOT/charon/build/charon" "$DTN_ROOT/demo/charon-bob.conf" \
    > "$OUT_DIR/charon_bob.log" 2>&1 &
echo $! > "$PID_DIR/charon_bob.pid"

sleep 2
echo ""
echo "Stack up. Logs: $OUT_DIR   PIDs: $PID_DIR"
echo "Run a smoke test before the full sweep, e.g.:"
echo "  sudo ip netns exec bob_ns $DTN_ROOT/apps/receiver 4000 1 &"
echo "  sudo ip netns exec alice_ns $DTN_ROOT/apps/sender 10.0.0.2 4000 1 64 0"
echo "Then: sudo bash run_arm4.sh"
echo "Tear down with: sudo bash stop_stack.sh $OUT_DIR"
