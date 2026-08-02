#!/usr/bin/env bash
# Arm 1 — CAN/CSP (raw CSP, no BP/CSPCL). Reuses bundle_overhead's
# csp_raw_sender/csp_raw_receiver binaries (unmodified) on the dedicated
# vcanlayer0 bus so this never touches vcan0 / the live demo.
#
# Raw CSP has no fragmentation/bundling concept: a single CSP packet is
# capped by the fixed CSP buffer size (CSPCL_CSP_BUFFER_DATA_SIZE = 256 B,
# minus a few bytes for the RDP header), so unlike Arm 2/3 this arm cannot
# be swept across the paper's 64/256/1024/4096 B sizes — it reports one
# fixed small-packet value, shared across every size column (see
# summarize.py). This is the expected shape, not a limitation of the test.
#
# Runs REPS independent repetitions of a COUNT-packet burst, each in its
# own log, so summarize.py can compute mean/stddev *across* repetitions
# rather than across packets within one burst (which are not independent —
# see the pool-serialization discussion in main.tex).
#
# Usage: run_arm1.sh [output_dir] [count] [reps]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BO_DIR="$REPO_ROOT/bundle_overhead"
OUT_DIR="${1:-$SCRIPT_DIR/results}/arm1"
COUNT="${2:-10}"
REPS="${3:-30}"
IFACE=vcanlayer0
UNIT_SIZE=64
RECV_TIMEOUT_S=30  # raw CSP has no retry logic, this arm is always fast

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

if [[ ! -x "$BO_DIR/csp_raw_sender" || ! -x "$BO_DIR/csp_raw_receiver" ]]; then
    echo "error: csp_raw_sender/csp_raw_receiver not found in $BO_DIR — run 'make' there first" >&2
    exit 1
fi

if ! ip link show "$IFACE" &>/dev/null; then
    echo "error: $IFACE not found — run 'sudo bash setup_root.sh' first" >&2
    exit 1
fi

echo "=== Arm 1: CAN/CSP (raw), fixed unit_size=${UNIT_SIZE}B, ${REPS} reps x ${COUNT} packets ==="
for rep in $(seq -w 1 "$REPS"); do
    log="$OUT_DIR/rep_${rep}.log"

    timeout "${RECV_TIMEOUT_S}s" \
        "$BO_DIR/csp_raw_receiver" 1 "$IFACE" "$COUNT" 20 15000 5000 > "$log" 2>&1 &
    recv_pid=$!
    sleep 0.3

    t_start=$(date +%s%N)
    "$BO_DIR/csp_raw_sender" 2 1 "$IFACE" "$COUNT" "$UNIT_SIZE" 0 20 >> "$log" 2>&1

    wait "$recv_pid" || echo "  rep $rep: receiver exited non-zero — check $log"
    t_end=$(date +%s%N)
    echo "$t_start $t_end" > "$OUT_DIR/rep_${rep}.timing"

    delivered=$(grep -c '^RECV ' "$log" || true)
    echo "  rep $rep: $delivered/$COUNT delivered"
done

echo "Arm 1 done. Logs in $OUT_DIR"
