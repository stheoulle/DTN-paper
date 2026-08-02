#!/bin/bash

set -e

RUNS=100
RESULT_DIR="arm3/throughput_results"

# Delays (seconds)
WAIT_AFTER_STOP=3
WAIT_AFTER_START=5
WAIT_BETWEEN_RUNS=3

mkdir -p "$RESULT_DIR"

for i in $(seq 1 $RUNS); do
    echo "========================================"
    echo "          Experiment run $i/$RUNS"
    echo "========================================"

    echo "[1/3] Stopping nodes..."
    sudo bash stop_nodes.sh

    echo "Waiting ${WAIT_AFTER_STOP}s for nodes to fully stop..."
    sleep $WAIT_AFTER_STOP


    echo "[2/3] Starting nodes..."
    sudo bash start_nodes.sh

    echo "Waiting ${WAIT_AFTER_START}s for nodes to be ready..."
    sleep $WAIT_AFTER_START


    echo "[3/3] Running Arm 3 benchmark..."
    sudo bash run_arm3.sh "$RESULT_DIR/run_$i" 10 1


    echo "Run $i completed."
    echo "Waiting ${WAIT_BETWEEN_RUNS}s before next run..."
    sleep $WAIT_BETWEEN_RUNS

done

echo "========================================"
echo "All $RUNS runs completed."
echo "Results stored in $RESULT_DIR"
echo "========================================"