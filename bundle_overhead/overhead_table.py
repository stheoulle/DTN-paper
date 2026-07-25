#!/usr/bin/env python3
"""
overhead_table.py -- analytic memory-overhead table for Section 3
(paper_comments.md): CSP/BP via CSPCL vs raw CSP, as a function of bundle
granularity N (CSP-packet-equivalents batched per bundle).

This computes BYTES of framing overhead, not timing: the timing side
(compute-time overhead) comes from the real, measured cspcl_send_bundle()
call durations logged by run_bundle_overhead.sh (the "mean_send_ms" column
in bundle_sender's SUMMARY line).

CSPCL constants below are taken directly from cspcl/src/cspcl.h and
cspcl/src/cspcl_config.h.

The BP7 framing size is NOT a fixed guess: this benchmark calls
cspcl_send_bundle() directly (bypassing a full BPA), so no real primary
block is ever encoded on the wire here, but RFC 9171 fully specifies the
CBOR encoding of a minimal bundle, so its exact byte count can be derived
rather than assumed. bp7_bundle_overhead_bytes() below implements that
derivation field-by-field:

  - Sec 4.1: a bundle is a CBOR *indefinite-length* array of blocks
    (1-byte start code 0x9f ... 1-byte break code 0xff).
  - Sec 4.3.1: the primary block is a CBOR array of 8 items for a
    non-fragmented, CRC-less bundle: version, flags, CRC type, destination
    EID, source EID, report-to EID, creation timestamp ([time, seq]),
    lifetime.
  - Sec 4.2.5: an EID is CBOR array [scheme-code, SSP]. For the "ipn"
    scheme (4.2.5.1.2) the SSP is itself [node-number, service-number],
    both CBOR unsigned integers -- this is what CSPCL/CSP addressing maps
    onto (TX_ADDR/RX_ADDR, CSPCL_PORT_BP). For "dtn:none" (4.2.5.1.1,
    used here as report-to since this benchmark requests no status
    reports) the SSP collapses to the single CBOR unsigned integer 0.
  - Sec 4.3.2: the mandatory payload block is a CBOR array of 5 items for
    a CRC-less block: block type, block number, flags, CRC type, and the
    block-type-specific data as a CBOR byte string (only the byte-string
    *length prefix* counts as overhead; the payload bytes themselves are
    the bundle_len already being swept, not extra framing).
  - Sec 4.1: CBOR unsigned integers (and, identically, CBOR array
    item-counts and byte-string length prefixes) take 1 byte for values
    0-23, 2 bytes for 24-255, 3 bytes for 256-65535, 5 bytes for
    256-4294967295 (RFC 8949 "additional information" length rule).

Because only the payload-length prefix and the creation-time value depend
on N and on wall-clock time, the resulting BP7 overhead is close to flat
across the whole N sweep (it only grows by 1 byte when bundle_len crosses
a CBOR length-prefix boundary at 24 or 256 bytes) -- unlike the old fixed
48-byte placeholder, this number is reproducible from the RFC text alone.
"""
import argparse
import math
import time

CSPCL_CSP_MTU = 256
CSPCL_SFP_HEADER_SIZE = 8
CSPCL_CSP_RDP_HEADER_SIZE = 5
CSPCL_MAX_PAYLOAD = CSPCL_CSP_MTU - CSPCL_SFP_HEADER_SIZE - CSPCL_CSP_RDP_HEADER_SIZE  # 243

# Matches run_bundle_overhead.sh defaults (TX_ADDR/RX_ADDR) and
# cspcl/src/cspcl.h's CSPCL_PORT_BP -- these are what the real ipn EIDs
# would carry if this benchmark's traffic were wrapped by a full BPA.
BENCH_SRC_NODE = 20
BENCH_DST_NODE = 21
BENCH_SVC = 10

IPN_SCHEME_CODE = 2
DTN_SCHEME_CODE = 1

# BP7 bundle lifetime, in milliseconds (Sec 4.1's "creation timestamp"
# companion field) -- 1 hour, a representative DTN contact-scale value.
BENCH_LIFETIME_MS = 3600 * 1000

# DTN epoch (2000-01-01T00:00:00Z) per RFC 9171 Sec 4.2.6.
DTN_EPOCH_UNIX_S = 946684800


def cbor_uint_size(value: int) -> int:
    """Bytes needed for a CBOR unsigned integer (RFC 8949 Sec 3.1) --
    also the correct size rule for a CBOR array item-count or byte-string
    length prefix, since the "additional information" length-encoding is
    shared across major types."""
    if value < 24:
        return 1
    elif value <= 0xFF:
        return 2
    elif value <= 0xFFFF:
        return 3
    elif value <= 0xFFFFFFFF:
        return 5
    else:
        return 9


def cbor_array_header_size(num_items: int) -> int:
    return cbor_uint_size(num_items)


def cbor_bytestring_header_size(length: int) -> int:
    return cbor_uint_size(length)


def ipn_eid_size(node: int, service: int) -> int:
    """[scheme-code, [node, service]] per RFC 9171 Sec 4.2.5.1.2."""
    return (cbor_array_header_size(2) + cbor_uint_size(IPN_SCHEME_CODE)
            + cbor_array_header_size(2) + cbor_uint_size(node) + cbor_uint_size(service))


def dtn_none_eid_size() -> int:
    """[scheme-code, 0] compact form for "dtn:none" per Sec 4.2.5.1.1."""
    return cbor_array_header_size(2) + cbor_uint_size(DTN_SCHEME_CODE) + cbor_uint_size(0)


def bp7_primary_block_size(creation_time_ms: int, creation_seq: int = 0,
                            lifetime_ms: int = BENCH_LIFETIME_MS,
                            flags: int = 0, crc_type: int = 0) -> int:
    """RFC 9171 Sec 4.3.1, non-fragment bundle: 8 array items if
    crc_type == 0, else 9 (adds a trailing CRC byte string)."""
    n_fields = 8 if crc_type == 0 else 9
    size = cbor_array_header_size(n_fields)
    size += cbor_uint_size(7)          # version = 7
    size += cbor_uint_size(flags)      # bundle processing control flags
    size += cbor_uint_size(crc_type)
    size += ipn_eid_size(BENCH_DST_NODE, BENCH_SVC)   # destination EID
    size += ipn_eid_size(BENCH_SRC_NODE, BENCH_SVC)   # source node ID
    size += dtn_none_eid_size()                       # report-to EID (no status reports requested)
    size += (cbor_array_header_size(2) + cbor_uint_size(creation_time_ms)
             + cbor_uint_size(creation_seq))           # creation timestamp [time, seq]
    size += cbor_uint_size(lifetime_ms)
    if crc_type != 0:
        crc_len = 2 if crc_type == 1 else 4
        size += cbor_bytestring_header_size(crc_len) + crc_len
    return size


def bp7_payload_block_size(payload_len: int, block_number: int = 1,
                            flags: int = 0, crc_type: int = 0) -> int:
    """RFC 9171 Sec 4.3.2, canonical (payload) block: 5 array items if
    crc_type == 0, else 6."""
    n_fields = 5 if crc_type == 0 else 6
    size = cbor_array_header_size(n_fields)
    size += cbor_uint_size(1)              # block type = payload (1)
    size += cbor_uint_size(block_number)
    size += cbor_uint_size(flags)
    size += cbor_uint_size(crc_type)
    size += cbor_bytestring_header_size(payload_len)  # byte-string length prefix only
    if crc_type != 0:
        crc_len = 2 if crc_type == 1 else 4
        size += cbor_bytestring_header_size(crc_len) + crc_len
    return size


def bp7_bundle_overhead_bytes(payload_len: int, crc_type: int = 0) -> int:
    """Total BP7 framing bytes around a payload of payload_len bytes:
    indefinite-array start (1B) + primary block + payload block (header
    only) + break code (1B). Does not include payload_len itself."""
    creation_time_ms = int((time.time() - DTN_EPOCH_UNIX_S) * 1000)
    indefinite_array_start = 1  # 0x9f
    break_byte = 1              # 0xff
    primary = bp7_primary_block_size(creation_time_ms, crc_type=crc_type)
    payload = bp7_payload_block_size(payload_len, crc_type=crc_type)
    return indefinite_array_start + primary + payload + break_byte


# Matches BENCH_HDR_SIZE in common.h -- every unit must hold at least the
# bench_unit_hdr, so csp_raw_sender.c/bundle_sender.c both clamp any
# requested --unit-size below this up to 36 bytes before ever sending a
# packet. run_bundle_overhead.sh passes its $UNIT_SIZE straight through to
# this script without applying that same clamp, so mirror it here --
# otherwise this table silently describes a unit_size that was never
# actually sent on the wire.
BENCH_HDR_SIZE = 36


def overhead_for(n_per_bundle: int, unit_size: int) -> dict:
    if unit_size < BENCH_HDR_SIZE:
        unit_size = BENCH_HDR_SIZE
    bundle_len = n_per_bundle * unit_size
    num_fragments = max(1, math.ceil(bundle_len / CSPCL_MAX_PAYLOAD))
    per_fragment_overhead = CSPCL_SFP_HEADER_SIZE + CSPCL_CSP_RDP_HEADER_SIZE
    cspcl_overhead_bytes = num_fragments * per_fragment_overhead
    bp7_overhead_bytes = bp7_bundle_overhead_bytes(bundle_len)
    total_overhead_bytes = bp7_overhead_bytes + cspcl_overhead_bytes
    return {
        "n_per_bundle": n_per_bundle,
        "bundle_len": bundle_len,
        "num_fragments": num_fragments,
        "cspcl_overhead_bytes": cspcl_overhead_bytes,
        "bp7_overhead_bytes": bp7_overhead_bytes,
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

    effective_unit_size = max(args.unit_size, BENCH_HDR_SIZE)
    clamp_note = (f" (requested {args.unit_size}B clamped up to {effective_unit_size}B, "
                   f"the minimum bench_unit_hdr size)" if effective_unit_size != args.unit_size else "")
    print(f"Analytic memory overhead -- unit_size={effective_unit_size} bytes{clamp_note}  "
          f"(BP7 overhead derived from RFC 9171 CBOR encoding rules, "
          f"varies by 1B across the sweep as bundle_len crosses a CBOR "
          f"length-prefix boundary; SFP+RDP per fragment="
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
