#!/usr/bin/env bash
# Runs all three arms back-to-back at the paper's standard sizes
# (64/256/1024/4096 B), REPS independent repetitions of a COUNT-packet burst
# each, and writes logs under results/. Statistics must be computed across
# repetitions, not across packets within one burst — see summarize.py.
#
# Requires root throughout (Arm 3 needs TUN + netns, and running the whole
# sweep under one privilege level avoids re-prompting for sudo mid-run).
#
# Usage: sudo bash run_all.sh [output_dir] [count] [reps]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (sudo bash run_all.sh) — Arm 3 needs TUN + netns" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/results}"
COUNT="${2:-10}"
REPS="${3:-30}"

if ! ip link show vcanlayer0 &>/dev/null; then
    echo "error: vcanlayer0 not found — run 'bash setup_root.sh' first" >&2
    exit 1
fi

bash "$SCRIPT_DIR/run_arm1.sh" "$OUT_DIR" "$COUNT" "$REPS"

# Always stop node-a/node-b on exit, even if an arm fails partway through —
# otherwise a crashed run leaves root-owned uD3TN processes holding the
# AAP2 sockets, breaking the next attempt.
trap 'bash "$SCRIPT_DIR/stop_nodes.sh"' EXIT

bash "$SCRIPT_DIR/start_nodes.sh"
sleep 1

bash "$SCRIPT_DIR/run_arm2.sh" "$OUT_DIR" "$COUNT" "$REPS"
bash "$SCRIPT_DIR/run_arm3.sh" "$OUT_DIR" "$COUNT" "$REPS"

echo ""
echo "All arms done. Results under: $OUT_DIR"
echo "Run 'python3 $SCRIPT_DIR/summarize.py $OUT_DIR' to build the comparison table."
