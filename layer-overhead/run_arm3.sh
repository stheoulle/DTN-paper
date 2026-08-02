#!/usr/bin/env bash
# Arm 3 — CAN/CSP/BP/CSP (Charon). Same node-a/node-b pair as Arm 2, plus a
# Charon instance in front of each, tunneling IP traffic CSP-peer-to-peer
# through the same single BP hop — isolates Charon's tunneling overhead from
# any multi-hop/routing confound. Requires start_nodes.sh AND
# setup_root.sh to have been run first. Must be run as root (TUN + netns).
#
# Runs REPS independent repetitions of a COUNT-packet burst per size (Charon
# stays up for the whole sweep — only the sender/receiver restart per rep),
# so summarize.py can compute mean/stddev *across* repetitions rather than
# across packets within one burst (not independent — see run_arm2.sh).
#
# Usage: sudo bash run_arm3.sh [output_dir] [count] [reps]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (sudo bash run_arm3.sh) — needs TUN + netns" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHARON_BIN="$REPO_ROOT/charon/build/charon"
SENDER="$REPO_ROOT/apps/sender"
RECEIVER="$REPO_ROOT/apps/receiver"
OUT_DIR="${1:-$SCRIPT_DIR/results}/arm3"
COUNT="${2:-10}"
REPS="${3:-30}"
PORT=4000
REMOTE=10.1.0.2
SIZES=(64 256 1024 4096)

# Same worst-case reasoning as run_arm2.sh: the underlying CSPCL retry
# budget is ~12s/bundle in the worst case, serialized across the burst.
RECV_TIMEOUT_S=$(( COUNT * 12 + 15 ))

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

for sock in /tmp/layer-node-a.aap2.socket /tmp/layer-node-b.aap2.socket; do
    if [[ ! -S "$sock" ]]; then
        echo "error: $sock not found — run start_nodes.sh first (as your normal user)" >&2
        exit 1
    fi
done

for ns in layer_a_ns layer_b_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        echo "error: netns $ns not found — run setup_root.sh first" >&2
        exit 1
    fi
done

if [[ ! -x "$CHARON_BIN" || ! -x "$SENDER" || ! -x "$RECEIVER" ]]; then
    echo "error: charon/apps binaries missing — build them first (see repo README / apps/Makefile)" >&2
    exit 1
fi

echo "=== starting Charon (node-a, node-b) ==="
ip netns exec layer_a_ns env CHARON_SECRET=layer_bench_secret \
    "$CHARON_BIN" "$SCRIPT_DIR/configs/node-a-charon.conf" > "$OUT_DIR/charon-a.log" 2>&1 &
charon_a_pid=$!
ip netns exec layer_b_ns env CHARON_SECRET=layer_bench_secret \
    "$CHARON_BIN" "$SCRIPT_DIR/configs/node-b-charon.conf" > "$OUT_DIR/charon-b.log" 2>&1 &
charon_b_pid=$!
sleep 1

cleanup() {
    kill "$charon_a_pid" "$charon_b_pid" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Arm 3: CAN/CSP/BP/CSP (Charon), ${REPS} reps x ${COUNT} packets/size ==="
echo "    (per-rep timeout: ${RECV_TIMEOUT_S}s)"
for size in "${SIZES[@]}"; do
    size_dir="$OUT_DIR/size_${size}"
    mkdir -p "$size_dir"
    echo "-- size=${size}B --"

    for rep in $(seq -w 1 "$REPS"); do
        log="$size_dir/rep_${rep}.log"

        timeout "${RECV_TIMEOUT_S}s" \
            ip netns exec layer_b_ns "$RECEIVER" "$PORT" "$COUNT" > "$log" 2>&1 &
        recv_pid=$!
        sleep 0.3

        t_start=$(date +%s%N)
        ip netns exec layer_a_ns "$SENDER" "$REMOTE" "$PORT" "$COUNT" "$size" 0 >> "$log" 2>&1

        wait "$recv_pid" || echo "  rep $rep: receiver exited non-zero — check $log"
        t_end=$(date +%s%N)
        echo "$t_start $t_end" > "$size_dir/rep_${rep}.timing"

        delivered=$(grep -c '^RECV ' "$log" || true)
        echo "  rep $rep: $delivered/$COUNT delivered"
    done
done

cleanup

echo "Arm 3 done. Logs in $OUT_DIR"
