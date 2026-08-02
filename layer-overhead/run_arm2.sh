#!/usr/bin/env bash
# Arm 2 — CAN/CSP/BP via a real uD3TN BPA (no Charon). Drives bundles
# through node-a's actual AAP2 -> BPA -> CSPCL CLA path, not a direct
# cspcl_send_bundle() call — requires start_nodes.sh to have been run first.
#
# Runs REPS independent repetitions of a COUNT-bundle burst per size, each
# in its own log, so summarize.py can compute mean/stddev *across*
# repetitions rather than across bundles within one burst (which are not
# independent — bundle N's latency depends on bundle N-1's full
# send-ack-reconnect cycle via the pool-wide mutex, see main.tex).
#
# Usage: run_arm2.sh [output_dir] [count] [reps]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/results}/arm2"
COUNT="${2:-10}"
REPS="${3:-30}"
SIZES=(64 256 1024 4096)

# Worst case per bundle: 2 send attempts x (CSPCL_ACK_TIMEOUT_MS=5s + SFP
# send time) before cspcl_send_bundle() gives up — roughly 12s/bundle if
# every single one fails and retries. Bundles are serialized (pool-wide
# mutex), so a burst's worst case scales with COUNT, not a fixed constant.
RECV_TIMEOUT_S=$(( COUNT * 12 + 15 ))

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

for sock in /tmp/layer-node-a.aap2.socket /tmp/layer-node-b.aap2.socket; do
    if [[ ! -S "$sock" ]]; then
        echo "error: $sock not found — run start_nodes.sh first" >&2
        exit 1
    fi
done

source "$REPO_ROOT/.venv/bin/activate"
cd "$SCRIPT_DIR/arm2-csp-bp"

echo "=== Arm 2: CAN/CSP/BP (real uD3TN bundle path), ${REPS} reps x ${COUNT} bundles/size ==="
echo "    (per-rep timeout: ${RECV_TIMEOUT_S}s)"
for size in "${SIZES[@]}"; do
    size_dir="$OUT_DIR/size_${size}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$size_dir"
    echo "-- size=${size}B --"

    for rep in $(seq -w 1 "$REPS"); do
        recv_log="$size_dir/rep_${rep}.log"
        send_log="$size_dir/rep_${rep}_send.log"
        agent_suffix="${size}-${rep}"

        timeout "${RECV_TIMEOUT_S}s" python3 bundle_bench_recv.py \
            --socket /tmp/layer-node-b.aap2.socket \
            --agentid "bench-${agent_suffix}" --count "$COUNT" > "$recv_log" 2>&1 &
        recv_pid=$!
        sleep 0.3

        t_start=$(date +%s%N)
        python3 bundle_bench_send.py \
            --socket /tmp/layer-node-a.aap2.socket \
            --agentid "bench-send-${agent_suffix}" \
            --count "$COUNT" --size "$size" --interval-ms 0 \
            "dtn://node-b.dtn/bench-${agent_suffix}" > "$send_log" 2>&1

        wait "$recv_pid" || echo "  rep $rep: receiver exited non-zero — check $recv_log"
        t_end=$(date +%s%N)
        echo "$t_start $t_end" > "$size_dir/rep_${rep}.timing"

        delivered=$(grep -c '^RECV ' "$recv_log" || true)
        echo "  rep $rep: $delivered/$COUNT delivered"
    done
done

echo "Arm 2 done. Logs in $OUT_DIR"
