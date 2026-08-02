#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
"""
bundle_bench_send — Arm 2 sender: real BP7 bundles over CSPCL via AAP2,
no Charon, no IP tunnel. Drives uD3TN's actual bundle path (send_adu over
AAP2 -> BPA -> CSPCL CLA -> CSP/RDP -> CAN), unlike bundle_overhead's Arm B
which calls cspcl_send_bundle() directly and bypasses any BPA.

Payload wire format matches apps/sender.c (see pkt_hdr.py) so RECV/latency
lines are directly comparable across all three arms.

Usage: bundle_bench_send.py --socket <aap2 unix socket> <dest_eid>
           [--count N] [--size BYTES] [--interval-ms MS]
"""
import argparse
import sys
import time

from pkt_hdr import build_packet, HDR_SIZE

from ud3tn_utils.aap2 import AAP2UnixClient, BundleADU, BundleADUFlags, ResponseStatus


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="AAP2 unix socket path")
    parser.add_argument("--agentid", default="bench-send", help="agent id to register")
    parser.add_argument("dest_eid", help="destination EID, e.g. dtn://node-b.dtn/bench")
    parser.add_argument("--count", type=int, default=10, help="number of bundles to send")
    parser.add_argument("--size", type=int, default=256, help="bundle payload size in bytes")
    parser.add_argument(
        "--interval-ms", type=int, default=0,
        help="delay between sends in ms (0 = burst, back-to-back)",
    )
    args = parser.parse_args()

    if args.size < HDR_SIZE:
        print(f"size clamped to minimum {HDR_SIZE} (header size)", file=sys.stderr)
        args.size = HDR_SIZE

    print(
        f"sending {args.count} bundle(s) to {args.dest_eid} "
        f"size={args.size} bytes interval={args.interval_ms} ms",
        file=sys.stderr,
    )

    client = AAP2UnixClient(address=args.socket)
    with client:
        secret = client.configure(args.agentid, subscribe=False)
        print(f"assigned agent secret: {secret}", file=sys.stderr)

        sent = []

        for seq in range(1, args.count + 1):
            payload = build_packet(seq, args.size)
            t0 = time.clock_gettime(time.CLOCK_MONOTONIC)

            client.send_adu(
                BundleADU(
                    dst_eid=args.dest_eid,
                    payload_length=len(payload),
                    adu_flags=[BundleADUFlags.BUNDLE_ADU_NORMAL],
                ),
                payload,
            )
            t1 = time.clock_gettime(time.CLOCK_MONOTONIC)

            print(f"send_adu duration={(t1-t0)*1000:.3f} ms")

            sent.append(seq)

            print(f"SEND seq={seq} size={args.size}")
            sys.stdout.flush()

            if args.interval_ms > 0 and seq < args.count:
                time.sleep(args.interval_ms / 1000.0)

        for _ in sent:
            response = client.receive_response()
            if response.response_status != ResponseStatus.RESPONSE_STATUS_SUCCESS:
                print(
                    f"unexpected response status {response.response_status}",
                    file=sys.stderr,
                )


if __name__ == "__main__":
    main()
