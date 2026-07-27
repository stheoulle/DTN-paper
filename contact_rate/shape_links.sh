#!/usr/bin/env bash
# shape_links.sh — enforce the demo/alice.cp contact plan's modeled rates
# as real bandwidth limits, instead of the routing-only metadata they are
# today (A-SABR's contact plan and unibo-bp-admin's --xmit-rate are both
# consumed by contact-graph routing logic only; nothing currently throttles
# the actual vcan0/loopback transport).
#
# Two hops, two different mechanisms:
#
#   - unibo<->hardy and hardy<->bob (CAN, CSPCL over vcan0, 50 kbit/s each
#     in alice.cp): a single tc tbf qdisc on vcan0, since both hops share
#     that one bus. Well-validated — see check_tc_vcan.sh.
#   - alice<->unibo (TCPCLv3 over loopback TCP, ports 4224/4225, 100
#     kbit/s in alice.cp): tc prio + tbf on `lo`, with iptables CLASSIFY
#     to steer only that port's traffic into the shaped band. Loopback
#     qdisc enforcement is less consistently reliable across kernels than
#     shaping a real interface — if the achieved-vs-ceiling numbers for
#     this hop look implausible (near-unshaped), verify with a manual
#     throughput check on ports 4224/4225 before trusting them.
#
# Usage:
#   sudo ./shape_links.sh up   [can_kbps=50] [tcp_kbps=100]
#   sudo ./shape_links.sh down

set -euo pipefail

ACTION="${1:-}"
CAN_KBPS="${2:-50}"
TCP_KBPS="${3:-100}"
CAN_IFACE="vcan0"
TCPCL_PORTS=(4224 4225)

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (tc/iptables require it)" >&2
    exit 1
fi

usage() {
    echo "usage: sudo $0 up [can_kbps=50] [tcp_kbps=100]" >&2
    echo "       sudo $0 down" >&2
    exit 1
}

shape_up() {
    if ! ip link show "$CAN_IFACE" >/dev/null 2>&1; then
        echo "error: $CAN_IFACE not found — run DEMO.md Phase 1 first" >&2
        exit 1
    fi

    echo "-- shaping $CAN_IFACE to ${CAN_KBPS}kbit/s (unibo<->hardy, hardy<->bob) --"
    # burst=64: libcsp's socketcan driver writes one struct can_frame (16
    # bytes) per write() call, so 64 bytes (4 frames) is comfortable
    # headroom above both that minimum and tbf's own per-HZ-tick floor,
    # without approaching the previous burst=1600 (100 frames). At 1600,
    # a multi-fragment CSPCL bundle whose total wire footprint is
    # comparable to or smaller than the burst allowance (e.g. 1024B, ~5
    # SFP fragments) could ride the initial full token bucket almost
    # entirely unshaped whenever the bucket had time to refill between
    # sends (256ms to refill 1600B @ 50kbit -- easily done between paced
    # bundles), making "achieved throughput" numbers look far better than
    # the real 50kbit/s rate. 64 bytes only buys ~10ms of free transfer,
    # negligible next to the multi-hundred-ms to multi-second transfers
    # being measured.
    tc qdisc replace dev "$CAN_IFACE" root tbf rate "${CAN_KBPS}kbit" burst 64 latency 5000ms

    echo "-- shaping loopback ports ${TCPCL_PORTS[*]} to ${TCP_KBPS}kbit/s (alice<->unibo) --"
    tc qdisc replace dev lo root handle 1: prio
    tc qdisc replace dev lo parent 1:3 handle 30: tbf rate "${TCP_KBPS}kbit" burst 3200 latency 5000ms
    for port in "${TCPCL_PORTS[@]}"; do
        iptables -t mangle -C OUTPUT -p tcp --dport "$port" -j CLASSIFY --set-class 1:3 2>/dev/null \
            || iptables -t mangle -A OUTPUT -p tcp --dport "$port" -j CLASSIFY --set-class 1:3
        iptables -t mangle -C OUTPUT -p tcp --sport "$port" -j CLASSIFY --set-class 1:3 2>/dev/null \
            || iptables -t mangle -A OUTPUT -p tcp --sport "$port" -j CLASSIFY --set-class 1:3
    done

    echo
    echo "Shaping applied. Verify with: tc -s qdisc show dev $CAN_IFACE; tc -s qdisc show dev lo"
}

shape_down() {
    echo "-- removing shaping from $CAN_IFACE --"
    tc qdisc del dev "$CAN_IFACE" root 2>/dev/null || true

    echo "-- removing shaping from lo --"
    for port in "${TCPCL_PORTS[@]}"; do
        iptables -t mangle -D OUTPUT -p tcp --dport "$port" -j CLASSIFY --set-class 1:3 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --sport "$port" -j CLASSIFY --set-class 1:3 2>/dev/null || true
    done
    tc qdisc del dev lo root 2>/dev/null || true

    echo "Shaping removed."
}

case "$ACTION" in
    up) shape_up ;;
    down) shape_down ;;
    *) usage ;;
esac
