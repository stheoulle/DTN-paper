#!/usr/bin/env python3
"""
overhead_table.py -- analytic memory-overhead table for Section 3
(paper_comments.md): CSP/BP via CSPCL vs raw CSP, as a function of bundle
granularity N (CSP-packet-equivalents batched per bundle).

This computes BYTES of framing overhead, not timing: the timing side
(compute-time overhead) comes from the real, measured cspcl_send_bundle()
call durations logged by run_bundle_overhead.sh (the "mean_send_ms" column
in bundle_sender's SUMMARY line).

Constants below are taken directly from cspcl/src/cspcl.h and
cspcl/src/cspcl_config.h. BP7_MIN_OVERHEAD_BYTES is the one analytic
approximation in this script: the benchmark calls cspcl_send_bundle()
directly (bypassing a full BPA), so no real BP7 primary block is ever
encoded on the wire here. It is a rough size for a minimal BP7 bundle
(short IPN source/destination EIDs, no extension blocks, no CRC) and
should be replaced with a measured value captured from a real
Hardy/Unibo-BP/uD3TN bundle if a more precise number is wanted for the
paper.
"""
import argparse
import math

CSPCL_CSP_MTU = 256
CSPCL_SFP_HEADER_SIZE = 8
CSPCL_CSP_RDP_HEADER_SIZE = 5
CSPCL_MAX_PAYLOAD = CSPCL_CSP_MTU - CSPCL_SFP_HEADER_SIZE - CSPCL_CSP_RDP_HEADER_SIZE  # 243
BP7_MIN_OVERHEAD_BYTES = 48  # analytic approximation, see module docstring


def overhead_for(n_per_bundle: int, unit_size: int) -> dict:
    bundle_len = n_per_bundle * unit_size
    num_fragments = max(1, math.ceil(bundle_len / CSPCL_MAX_PAYLOAD))
    per_fragment_overhead = CSPCL_SFP_HEADER_SIZE + CSPCL_CSP_RDP_HEADER_SIZE
    cspcl_overhead_bytes = num_fragments * per_fragment_overhead
    total_overhead_bytes = BP7_MIN_OVERHEAD_BYTES + cspcl_overhead_bytes
    return {
        "n_per_bundle": n_per_bundle,
        "bundle_len": bundle_len,
        "num_fragments": num_fragments,
        "cspcl_overhead_bytes": cspcl_overhead_bytes,
        "bp7_overhead_bytes": BP7_MIN_OVERHEAD_BYTES,
        "total_overhead_bytes": total_overhead_bytes,
        "overhead_ratio": total_overhead_bytes / bundle_len if bundle_len else float("inf"),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--unit-size", type=int, default=32,
                     help="bytes per CSP-packet-equivalent unit (default: 32)")
    ap.add_argument("--sweep", type=int, nargs="+", default=[1, 2, 4, 8, 16, 32, 64],
                     help="N values (CSP packets aggregated per bundle) to sweep")
    ap.add_argument("--csv", action="store_true", help="emit CSV instead of a text table")
    args = ap.parse_args()

    rows = [overhead_for(n, args.unit_size) for n in args.sweep]

    if args.csv:
        print("n_per_bundle,bundle_len,num_fragments,cspcl_overhead_bytes,"
              "bp7_overhead_bytes,total_overhead_bytes,overhead_ratio_pct")
        for r in rows:
            print(f"{r['n_per_bundle']},{r['bundle_len']},{r['num_fragments']},"
                  f"{r['cspcl_overhead_bytes']},{r['bp7_overhead_bytes']},"
                  f"{r['total_overhead_bytes']},{r['overhead_ratio']*100:.2f}")
        return

    print(f"Analytic memory overhead -- unit_size={args.unit_size} bytes  "
          f"(BP7 approx={BP7_MIN_OVERHEAD_BYTES}B, SFP+RDP per fragment="
          f"{CSPCL_SFP_HEADER_SIZE + CSPCL_CSP_RDP_HEADER_SIZE}B, "
          f"max fragment payload={CSPCL_MAX_PAYLOAD}B)\n")
    print(f"{'N':>4}  {'bundle_len':>10}  {'fragments':>9}  {'cspcl_ovh':>9}  "
          f"{'bp7_ovh':>7}  {'total_ovh':>9}  {'overhead%':>9}")
    for r in rows:
        print(f"{r['n_per_bundle']:>4}  {r['bundle_len']:>10}  {r['num_fragments']:>9}  "
              f"{r['cspcl_overhead_bytes']:>9}  {r['bp7_overhead_bytes']:>7}  "
              f"{r['total_overhead_bytes']:>9}  {r['overhead_ratio']*100:>8.2f}%")


if __name__ == "__main__":
    main()
