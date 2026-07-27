#!/usr/bin/env python3
"""
ceiling.py -- theoretical application-throughput ceiling at a given
nominal contact rate (demo/alice.cp's 50/100 kbit/s), for a given
end-to-end application payload size, accounting for every framing layer
actually on the wire.

This is the "reference ceiling" column paper_comments.md item 1 asks for:
"add a reference column to the output table with the theoretical ceiling
for each hop combination [...] so the paper can say 'X% of theoretical
capacity achieved' rather than just a raw kB/s number."

Two hops, two models, both driven by the real constants involved (not
assumed round numbers):

  - CAN hops (unibo<->hardy, hardy<->bob, 50 kbit/s each in alice.cp):
    BP7 (RFC 9171 CBOR framing, same derivation as
    bundle_overhead/overhead_table.py) -> CSPCL/SFP fragmentation -> CSP
    header + libcsp's CAN fragmentation protocol (CFP) -> raw extended-ID
    CAN 2.0B frame overhead, bit for bit. This is the rigorously derived
    half of this tool.
  - alice<->unibo hop (TCPCLv3 over TCP/loopback, 100 kbit/s in
    alice.cp): BP7 framing -> an approximate TCPCLv3 segment header size
    -> standard TCP/IP header overhead per MSS-sized segment. Marked as
    an approximation throughout -- this hop is never the binding
    constraint anyway since the CAN hops are half its nominal rate.
"""
import argparse
import math

# ---------------------------------------------------------------------------
# BP7 (RFC 9171) -- identical derivation to bundle_overhead/overhead_table.py
# ---------------------------------------------------------------------------

IPN_SCHEME_CODE = 2
DTN_SCHEME_CODE = 1
BENCH_SRC_NODE = 1   # unibo, per demo/alice-eid-map.json (ipn:1.0)
BENCH_DST_NODE = 3   # bob
BENCH_SVC = 0
BENCH_LIFETIME_MS = 3600 * 1000


def cbor_uint_size(value: int) -> int:
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
    return (cbor_array_header_size(2) + cbor_uint_size(IPN_SCHEME_CODE)
            + cbor_array_header_size(2) + cbor_uint_size(node) + cbor_uint_size(service))


def dtn_none_eid_size() -> int:
    return cbor_array_header_size(2) + cbor_uint_size(DTN_SCHEME_CODE) + cbor_uint_size(0)


def bp7_primary_block_size(creation_time_ms: int, creation_seq: int = 0,
                            lifetime_ms: int = BENCH_LIFETIME_MS, flags: int = 0,
                            crc_type: int = 0) -> int:
    n_fields = 8 if crc_type == 0 else 9
    size = cbor_array_header_size(n_fields)
    size += cbor_uint_size(7)
    size += cbor_uint_size(flags)
    size += cbor_uint_size(crc_type)
    size += ipn_eid_size(BENCH_DST_NODE, BENCH_SVC)
    size += ipn_eid_size(BENCH_SRC_NODE, BENCH_SVC)
    size += dtn_none_eid_size()
    size += (cbor_array_header_size(2) + cbor_uint_size(creation_time_ms)
             + cbor_uint_size(creation_seq))
    size += cbor_uint_size(lifetime_ms)
    if crc_type != 0:
        crc_len = 2 if crc_type == 1 else 4
        size += cbor_bytestring_header_size(crc_len) + crc_len
    return size


def bp7_payload_block_size(payload_len: int, block_number: int = 1, flags: int = 0,
                            crc_type: int = 0) -> int:
    n_fields = 5 if crc_type == 0 else 6
    size = cbor_array_header_size(n_fields)
    size += cbor_uint_size(1)
    size += cbor_uint_size(block_number)
    size += cbor_uint_size(flags)
    size += cbor_uint_size(crc_type)
    size += cbor_bytestring_header_size(payload_len)
    if crc_type != 0:
        crc_len = 2 if crc_type == 1 else 4
        size += cbor_bytestring_header_size(crc_len) + crc_len
    return size


def bp7_bundle_overhead_bytes(payload_len: int, crc_type: int = 0) -> int:
    import time
    DTN_EPOCH_UNIX_S = 946684800
    creation_time_ms = int((time.time() - DTN_EPOCH_UNIX_S) * 1000)
    indefinite_array_start = 1
    break_byte = 1
    primary = bp7_primary_block_size(creation_time_ms, crc_type=crc_type)
    payload = bp7_payload_block_size(payload_len, crc_type=crc_type)
    return indefinite_array_start + primary + payload + break_byte


# ---------------------------------------------------------------------------
# CSPCL / SFP (cspcl/src/cspcl_config.h)
# ---------------------------------------------------------------------------

CSPCL_CSP_MTU = 256
CSPCL_SFP_HEADER_SIZE = 8
CSPCL_CSP_RDP_HEADER_SIZE = 5
CSPCL_MAX_PAYLOAD = CSPCL_CSP_MTU - CSPCL_SFP_HEADER_SIZE - CSPCL_CSP_RDP_HEADER_SIZE  # 243

# ---------------------------------------------------------------------------
# CSP header + libcsp's CAN Fragmentation Protocol (CFP)
# (libcsp/include/csp/csp_types.h, libcsp/src/interfaces/csp_if_can.c)
# ---------------------------------------------------------------------------

CSP_HEADER_BYTES = 4          # CSP_HEADER_BITS=32 -> priority+src+dst+ports+flags
CFP_LENGTH_FIELD_BYTES = 2    # uint16_t packet length, first CAN frame only
CFP_OVERHEAD_BYTES = CSP_HEADER_BYTES + CFP_LENGTH_FIELD_BYTES  # 6, csp_if_can.c CFP_OVERHEAD
MAX_BYTES_IN_CAN_FRAME = 8    # classic CAN payload ceiling

# ---------------------------------------------------------------------------
# Raw CAN 2.0B (extended, 29-bit ID) frame bit-level overhead, per frame,
# excluding data payload bits. CSP-over-CAN always uses extended IDs (see
# CFP_HOST_SIZE+CFP_TYPE_SIZE+CFP_REMAIN_SIZE+CFP_ID_SIZE = 5+1+8+10 = 24
# id-carrying bits, which only fit in the 29-bit extended identifier, not
# the 11-bit standard one).
#
#   SOF(1) + ID_A(11) + SRR(1) + IDE(1) + ID_B(18) + RTR(1) + r1,r0(2)
#   + DLC(4) + CRC(15) + CRC delim(1) + ACK slot(1) + ACK delim(1)
#   + EOF(7) + intermission(3) = 67 bits, independent of DLC/data length.
# ---------------------------------------------------------------------------

CAN_EFF_FIXED_OVERHEAD_BITS = 67


def sfp_fragments(bundle_len: int) -> list:
    """Bytes of *user* SFP payload in each fragment (<=CSPCL_MAX_PAYLOAD)."""
    if bundle_len <= 0:
        return [0]
    fragments = []
    remaining = bundle_len
    while remaining > 0:
        frag = min(remaining, CSPCL_MAX_PAYLOAD)
        fragments.append(frag)
        remaining -= frag
    return fragments


def can_bits_for_csp_packet(csp_payload_len: int, stuffing_margin: float) -> int:
    """Total raw CAN bus bits (fixed framing + data, all frames) needed to
    carry one CSP packet (a single CSPCL/SFP fragment plus its own SFP+RDP
    headers) over libcsp's CFP CAN fragmentation."""
    wire_bytes = CFP_OVERHEAD_BYTES + csp_payload_len
    n_frames = math.ceil(wire_bytes / MAX_BYTES_IN_CAN_FRAME)
    total_bits = 0
    remaining = wire_bytes
    for _ in range(n_frames):
        frame_bytes = min(MAX_BYTES_IN_CAN_FRAME, remaining)
        remaining -= frame_bytes
        total_bits += CAN_EFF_FIXED_OVERHEAD_BITS + frame_bytes * 8
    return int(total_bits * stuffing_margin)


def can_hop_ceiling(app_payload_bytes: int, can_kbps: float, stuffing_margin: float = 1.0) -> dict:
    """Theoretical ceiling for one CAN hop (unibo<->hardy or hardy<->bob)
    carrying a BP7 bundle whose application payload is app_payload_bytes."""
    bp7_ovh = bp7_bundle_overhead_bytes(app_payload_bytes)
    bundle_len = app_payload_bytes + bp7_ovh

    total_bits = 0
    for frag_payload in sfp_fragments(bundle_len):
        csp_payload_len = frag_payload + CSPCL_SFP_HEADER_SIZE + CSPCL_CSP_RDP_HEADER_SIZE
        total_bits += can_bits_for_csp_packet(csp_payload_len, stuffing_margin)

    time_s = total_bits / (can_kbps * 1000.0)
    throughput_Bps = app_payload_bytes / time_s if time_s > 0 else float("inf")

    return {
        "app_payload_bytes": app_payload_bytes,
        "bp7_overhead_bytes": bp7_ovh,
        "bundle_len": bundle_len,
        "n_fragments": len(sfp_fragments(bundle_len)),
        "total_bits_on_wire": total_bits,
        "time_s": time_s,
        "throughput_Bps": throughput_Bps,
        "throughput_kBps": throughput_Bps / 1000.0,
    }


# ---------------------------------------------------------------------------
# alice<->unibo hop: TCPCLv3 over TCP/loopback. Approximate model -- this
# hop is never the binding constraint (100 kbit/s nominal vs. 50 kbit/s on
# the CAN hops), so it doesn't need CAN's level of bit-exact rigor to be
# useful, but the TCPCLv3 XFER_SEGMENT header size below is an estimate,
# not verified against the uD3TN/Unibo-BP source -- refine if this hop's
# number needs to be precise for the paper.
# ---------------------------------------------------------------------------

TCPCLV3_SEGMENT_OVERHEAD_BYTES = 6   # approximate: 1B flags + up to 4B SDNV length + slack
TCP_IP_HEADER_BYTES = 40             # 20B IPv4 + 20B TCP, no options
DEFAULT_MSS = 1460


def tcp_hop_ceiling(app_payload_bytes: int, tcp_kbps: float, mss: int = DEFAULT_MSS) -> dict:
    bp7_ovh = bp7_bundle_overhead_bytes(app_payload_bytes)
    bundle_len = app_payload_bytes + bp7_ovh
    tcpcl_len = bundle_len + TCPCLV3_SEGMENT_OVERHEAD_BYTES

    n_segments = max(1, math.ceil(tcpcl_len / mss))
    total_bytes = tcpcl_len + n_segments * TCP_IP_HEADER_BYTES
    total_bits = total_bytes * 8

    time_s = total_bits / (tcp_kbps * 1000.0)
    throughput_Bps = app_payload_bytes / time_s if time_s > 0 else float("inf")

    return {
        "app_payload_bytes": app_payload_bytes,
        "bp7_overhead_bytes": bp7_ovh,
        "bundle_len": bundle_len,
        "n_segments": n_segments,
        "total_bits_on_wire": total_bits,
        "time_s": time_s,
        "throughput_Bps": throughput_Bps,
        "throughput_kBps": throughput_Bps / 1000.0,
    }


def end_to_end_ceiling(app_payload_bytes: int, can_kbps: float, tcp_kbps: float,
                        stuffing_margin: float = 1.0) -> dict:
    """End-to-end ceiling across all 3 hops (alice->unibo->hardy->bob) is
    bounded by the slowest hop's *time*, since the chain is serial
    store-and-forward, not a pipeline: the bundle must fully arrive at
    each node before being forwarded. Reports the binding (slowest) hop
    explicitly rather than just picking the smallest kbps number, since
    per-hop framing overhead differs too."""
    can = can_hop_ceiling(app_payload_bytes, can_kbps, stuffing_margin)
    tcp = tcp_hop_ceiling(app_payload_bytes, tcp_kbps)
    # unibo<->hardy and hardy<->bob are both CAN hops at the same rate in
    # alice.cp, so the end-to-end time is dominated by 2x the CAN hop time
    # plus 1x the TCP hop time.
    total_time_s = tcp["time_s"] + 2 * can["time_s"]
    throughput_Bps = app_payload_bytes / total_time_s if total_time_s > 0 else float("inf")
    return {
        "app_payload_bytes": app_payload_bytes,
        "can_hop": can,
        "tcp_hop": tcp,
        "total_time_s": total_time_s,
        "throughput_Bps": throughput_Bps,
        "throughput_kBps": throughput_Bps / 1000.0,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sweep", type=int, nargs="+", default=[64, 256, 1024, 4096],
                     help="application payload sizes (bytes) to compute, matching apps/measure.sh SIZES")
    ap.add_argument("--can-kbps", type=float, default=50.0,
                     help="nominal CAN hop rate, kbit/s (default: 50, matches demo/alice.cp)")
    ap.add_argument("--tcp-kbps", type=float, default=100.0,
                     help="nominal alice<->unibo rate, kbit/s (default: 100, matches demo/alice.cp)")
    ap.add_argument("--stuffing-margin", type=float, default=1.0,
                     help="multiply CAN bit count by this to approximate bit-stuffing overhead "
                          "(1.0 = none/best-case; real buses commonly see ~1.10-1.20 worst-case)")
    ap.add_argument("--csv", action="store_true", help="emit CSV instead of a text table")
    args = ap.parse_args()

    rows = [end_to_end_ceiling(n, args.can_kbps, args.tcp_kbps, args.stuffing_margin)
            for n in args.sweep]

    if args.csv:
        print("payload_bytes,can_hop_kBps,tcp_hop_kBps,end_to_end_kBps,end_to_end_time_s")
        for r in rows:
            print(f"{r['app_payload_bytes']},{r['can_hop']['throughput_kBps']:.2f},"
                  f"{r['tcp_hop']['throughput_kBps']:.2f},{r['throughput_kBps']:.2f},"
                  f"{r['total_time_s']:.4f}")
        return

    print(f"Theoretical throughput ceiling -- CAN hops @ {args.can_kbps}kbit/s, "
          f"alice<->unibo @ {args.tcp_kbps}kbit/s"
          + (f", stuffing margin x{args.stuffing_margin}" if args.stuffing_margin != 1.0 else ""))
    print()
    print(f"{'payload(B)':>10}  {'CAN hop kB/s':>12}  {'TCP hop kB/s':>12}  "
          f"{'end-to-end kB/s':>16}  {'end-to-end time(s)':>19}")
    for r in rows:
        print(f"{r['app_payload_bytes']:>10}  {r['can_hop']['throughput_kBps']:>12.2f}  "
              f"{r['tcp_hop']['throughput_kBps']:>12.2f}  {r['throughput_kBps']:>16.2f}  "
              f"{r['total_time_s']:>19.4f}")


if __name__ == "__main__":
    main()
