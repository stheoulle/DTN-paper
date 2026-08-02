#!/usr/bin/env bash
# One-time root setup for the layer-overhead benchmark: a dedicated vcan
# interface and network namespaces, fully separate from the main demo's
# vcan0/alice_ns/bob_ns so this benchmark can run without disturbing (or
# being disturbed by) a live DEMO.md session.
#
# Usage: sudo bash layer-overhead/setup_root.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (sudo bash setup_root.sh)" >&2
    exit 1
fi

modprobe vcan

if ! ip link show vcanlayer0 &>/dev/null; then
    ip link add dev vcanlayer0 type vcan
fi
ip link set up vcanlayer0
echo "vcanlayer0: $(ip link show vcanlayer0 | head -1)"

for ns in layer_a_ns layer_b_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        ip netns add "$ns"
    fi
done
echo "netns: $(ip netns list | grep layer_)"

echo ""
echo "Setup complete. vcanlayer0 and layer_a_ns/layer_b_ns are ready."
echo "Run the benchmark arms as your normal user; only Arm 3 (Charon, TUN)"
echo "needs 'sudo ip netns exec' per-invocation, same as DEMO.md."
