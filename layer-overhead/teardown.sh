#!/usr/bin/env bash
# Stops all layer-overhead processes and (if run as root) removes the
# dedicated vcanlayer0 interface and network namespaces.
#
# Usage: bash layer-overhead/teardown.sh        # stop processes only
#        sudo bash layer-overhead/teardown.sh   # also remove vcan/netns

pkill -f "csp_raw_sender|csp_raw_receiver" 2>/dev/null || true
pkill -f "build/posix/ud3tn -e dtn://node-a.dtn\|build/posix/ud3tn -e dtn://node-b.dtn" 2>/dev/null || true
pkill -f "charon/build/charon .*layer-overhead" 2>/dev/null || true
pkill -f "bundle_bench_send.py|bundle_bench_recv.py" 2>/dev/null || true

rm -f /tmp/layer-node-a.aap2.socket /tmp/layer-node-a.socket
rm -f /tmp/layer-node-b.aap2.socket /tmp/layer-node-b.socket

if [[ $EUID -eq 0 ]]; then
    ip link del vcanlayer0 2>/dev/null || true
    ip netns del layer_a_ns 2>/dev/null || true
    ip netns del layer_b_ns 2>/dev/null || true
    echo "vcanlayer0 and layer_a_ns/layer_b_ns removed."
else
    echo "Processes and sockets cleaned up. Re-run with sudo to also remove vcanlayer0/netns."
fi
