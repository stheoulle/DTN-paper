#!/usr/bin/env bash
# One-time root setup for the full 4-node chain (DEMO.md Phase 1):
# vcan0 and alice_ns/bob_ns, used by every T1-T11 process. Idempotent.
#
# Deliberately reuses DEMO.md's vcan0/alice_ns/bob_ns names (not
# layer-overhead's vcanlayer0/layer_a_ns/layer_b_ns) -- this is the same
# full end-to-end stack DEMO.md documents manually, just automated and
# repeated many times for statistics.
#
# Usage: sudo bash setup_root.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (sudo bash setup_root.sh)" >&2
    exit 1
fi

modprobe vcan

if ! ip link show vcan0 &>/dev/null; then
    ip link add dev vcan0 type vcan
fi
ip link set up vcan0
echo "vcan0: $(ip link show vcan0 | head -1)"

for ns in alice_ns bob_ns; do
    if ! ip netns list | grep -qw "$ns"; then
        ip netns add "$ns"
    fi
done
echo "netns: $(ip netns list | grep -E 'alice_ns|bob_ns')"

echo ""
echo "Setup complete. Run start_stack.sh next (as your normal user, it will"
echo "sudo internally only for the two Charon instances)."
