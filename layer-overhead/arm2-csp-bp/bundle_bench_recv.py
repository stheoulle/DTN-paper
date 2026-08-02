#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
"""
bundle_bench_recv — Arm 2 receiver: registers an AAP2 agent, waits for
bundles sent by bundle_bench_send.py, decodes the pkt_hdr embedded in each
payload, and prints per-bundle latency plus a final summary in the same
format as apps/receiver.c (Arm 3) and csp_raw_receiver (Arm 1).

Usage: bundle_bench_recv.py --socket <aap2 unix socket> [--agentid bench]
           [--count N]
"""
import argparse
import math
import sys

from pkt_hdr import latency_ms, parse_packet

from ud3tn_utils.aap2 import (
    AAP2ServerDisconnected,
    AAP2UnixClient,
    ResponseStatus,
)


def print_stats(samples, expected):
    if not samples:
        print("\n--- no packets received ---")
        return

    n = len(samples)
    mean = sum(samples) / n
    vmin, vmax = min(samples), max(samples)
    var = sum((s - mean) ** 2 for s in samples) / n
    stddev = math.sqrt(var)

    print("\n--- measurement summary ---")
    if expected:
        print(f"received : {n} / {expected}  ({100.0 * n / expected:.1f}% delivery rate)")
    else:
        print(f"received : {n}")
    print(
        f"latency  : min={vmin:.3f} ms  mean={mean:.3f} ms  "
        f"max={vmax:.3f} ms  stddev={stddev:.3f} ms"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True, help="AAP2 unix socket path")
    parser.add_argument("--agentid", default="bench-recv", help="agent id to register")
    parser.add_argument(
        "--count", type=int, default=0,
        help="expected bundle count; exit and print stats after receiving this many "
             "(0 = run until disconnected/Ctrl-C)",
    )
    args = parser.parse_args()

    samples = []

    client = AAP2UnixClient(address=args.socket)
    with client:
        secret = client.configure(args.agentid, subscribe=True)
        print(f"assigned agent secret: {secret}", file=sys.stderr)
        print("waiting for bundles...", file=sys.stderr)

        try:
            while True:
                try:
                    msg = client.receive_msg()
                except AAP2ServerDisconnected:
                    print("uD3TN closed the connection.", file=sys.stderr)
                    break

                msg_type = msg.WhichOneof("msg")
                if msg_type == "keepalive":
                    client.send_response_status(ResponseStatus.RESPONSE_STATUS_ACK)
                    continue
                if msg_type != "adu":
                    continue

                _adu_msg, bundle_data = client.receive_adu(msg.adu)
                client.send_response_status(ResponseStatus.RESPONSE_STATUS_SUCCESS)

                parsed = parse_packet(bundle_data)
                if parsed is None:
                    print(f"bad/short packet ({len(bundle_data)} bytes), skipping",
                          file=sys.stderr)
                    continue

                seq, send_sec, send_nsec, size = parsed
                lat = latency_ms(send_sec, send_nsec)
                samples.append(lat)

                print(f"RECV seq={seq} latency={lat:.3f}ms size={size}")
                sys.stdout.flush()

                if args.count and len(samples) >= args.count:
                    break
        except KeyboardInterrupt:
            print("interrupted", file=sys.stderr)

    print_stats(samples, args.count)


if __name__ == "__main__":
    main()
