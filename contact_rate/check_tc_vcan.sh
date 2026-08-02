#!/usr/bin/env bash
# check_tc_vcan.sh — sanity check: does `tc qdisc ... tbf` actually shape
# traffic on a virtual CAN interface, or does it silently no-op?
#
# vcan is a software-only device with no real bus arbitration, and `tc`
# qdiscs are overwhelmingly validated against IP traffic in practice, not
# CAN frames. Before trusting any "shaped to 50/100 kbps" benchmark number,
# this needs to be confirmed empirically rather than assumed.
#
# Method: create a throwaway vcan interface (never vcan0/vcanbench0, so
# this never disturbs the demo or bundle_overhead's own interface), send a
# fixed, known amount of traffic through it twice — once unshaped, once
# with a tc tbf qdisc applied at TARGET_KBPS — and compare wall-clock time
# for the two runs. If shaping works, the shaped run should take
# noticeably longer and land close to the target rate; if `tc` is silently
# not applying, the two runs will look the same (both fast).
#
# Usage: sudo ./check_tc_vcan.sh [target_kbps]

set -euo pipefail

TARGET_KBPS="${1:-50}"
IFACE="vcanshapecheck0"
FRAME_COUNT=1500          # frames per run
FRAME_BYTES=8             # full CAN payload per frame (DLC=8)
# Fixed ID + alternating-bit data pattern: cangen's own documented way to
# generate a clean, predictable busload without bit-stuffing distorting
# the byte count (see `cangen` --help examples).
CAN_ID="555"
CAN_DATA="CCCCCCCCCCCCCCCC"

if [[ $EUID -ne 0 ]]; then
    echo "error: must run as root (ip link / tc require it)" >&2
    exit 1
fi

for bin in cangen tc ip; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "error: '$bin' not found — install can-utils / iproute2" >&2
        exit 1
    fi
done

cleanup() {
    ip link set "$IFACE" down 2>/dev/null || true
    ip link delete "$IFACE" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== tc-on-vcan sanity check (target: ${TARGET_KBPS} kbit/s) ==="
echo

# Fresh scratch interface, no qdisc yet.
cleanup
ip link add dev "$IFACE" type vcan
ip link set up "$IFACE"

run_cangen() {
    # -p 100: poll on ENOBUFS (wait for tx queue space) instead of
    # silently dropping frames when the qdisc is throttling — without
    # this, cangen just discards frames the shaped queue can't accept
    # immediately, and the whole run finishes "instantly" regardless of
    # tc, which would make this check meaningless.
    cangen "$IFACE" -g 0 -p 100 -L 8 -I "$CAN_ID" -D "$CAN_DATA" -n "$FRAME_COUNT"
}

time_run() {
    local start end
    start=$(date +%s%N)
    run_cangen
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 )) # ms
}

echo "--- baseline: no qdisc ---"
baseline_ms=$(time_run)
baseline_kbps=$(python3 -c "print(round($FRAME_COUNT * $FRAME_BYTES * 8 / ($baseline_ms/1000.0) / 1000, 1))")
echo "sent ${FRAME_COUNT} frames (${FRAME_BYTES}B payload each) in ${baseline_ms}ms -> ${baseline_kbps} kbit/s (payload only, unshaped)"
echo

echo "--- shaped: tc qdisc tbf rate ${TARGET_KBPS}kbit ---"
# burst=64 matches shape_links.sh -- validate the actual configuration the
# benchmark uses, not a more generous one that would mask a burst-allowance
# artifact (see shape_links.sh's comment on this value).
tc qdisc add dev "$IFACE" root tbf rate "${TARGET_KBPS}kbit" burst 64 latency 5000ms
shaped_ms=$(time_run)
shaped_kbps=$(python3 -c "print(round($FRAME_COUNT * $FRAME_BYTES * 8 / ($shaped_ms/1000.0) / 1000, 1))")
echo "sent ${FRAME_COUNT} frames in ${shaped_ms}ms -> ${shaped_kbps} kbit/s (payload only, shaped)"
tc qdisc del dev "$IFACE" root
echo

python3 -c "
target = $TARGET_KBPS
baseline = $baseline_kbps
shaped = $shaped_kbps

print('=== verdict ===')
if shaped >= baseline * 0.8:
    print(f'FAIL: shaped run ({shaped} kbit/s) is barely slower than the unshaped')
    print(f'      baseline ({baseline} kbit/s) -- tc does not appear to be')
    print('      throttling this vcan interface. Do not trust shaped')
    print('      benchmark numbers without investigating further (try a')
    print('      real CAN interface/hardware instead of vcan for this test).')
    raise SystemExit(1)

# shaped_kbps only counts frame *payload* bits; real CAN frames add ~65-70
# bits of fixed overhead per frame on top of the 64 payload bits, so the
# achieved payload-only rate should land at roughly payload/(payload+overhead)
# of the nominal target, not exactly at it. Use a generous band since this
# script only needs to confirm tc has *real* throttling effect, not measure
# it precisely (that's ceiling.py's job).
lo, hi = target * 0.3, target * 1.1
if lo <= shaped <= hi:
    print(f'PASS: shaped rate ({shaped} kbit/s) is well below the unshaped')
    print(f'      baseline ({baseline} kbit/s) and in the expected range for')
    print(f'      a {target} kbit/s nominal target once real CAN frame')
    print('      overhead is accounted for. tc is genuinely throttling this')
    print('      vcan interface.')
else:
    print(f'WARN: shaping had an effect (baseline {baseline} -> shaped {shaped}')
    print(f'      kbit/s) but shaped rate is outside the expected band for a')
    print(f'      {target} kbit/s target ({lo:.1f}-{hi:.1f} kbit/s). tc is doing')
    print('      something, but double-check burst/latency tuning before')
    print('      trusting absolute numbers from shape_links.sh.')
"
