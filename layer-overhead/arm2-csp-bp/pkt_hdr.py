# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
"""
Wire-format header shared with apps/sender.c and apps/receiver.c (Arm 3) and
bundle_overhead's bench_unit_hdr (Arm 1), so all three arms' RECV/latency
output lines are directly comparable.

Matches apps/sender.c's `struct __attribute__((packed)) pkt_hdr`:

    uint32_t magic;
    uint32_t seq;
    int64_t  send_sec;
    int64_t  send_nsec;
    uint32_t size;

28 bytes total, little-endian (matches the x86_64 hosts this benchmark runs
on; both sides of every arm run on the same machine, so there is no cross-
architecture concern and no clock-sync problem for latency measurement).
"""
import struct
import time

PKT_MAGIC = 0xD3CA0000
_STRUCT = struct.Struct("<IIqqI")
HDR_SIZE = _STRUCT.size  # 28
assert HDR_SIZE == 28


def build_packet(seq: int, size: int) -> bytes:
    """Build a size-byte payload: header + deterministic 0xAA padding."""
    if size < HDR_SIZE:
        raise ValueError(f"size must be >= {HDR_SIZE} (header size)")
    send_ts = time.clock_gettime(time.CLOCK_MONOTONIC)
    send_sec = int(send_ts)
    send_nsec = int((send_ts - send_sec) * 1e9)
    hdr = _STRUCT.pack(PKT_MAGIC, seq, send_sec, send_nsec, size)
    return hdr + b"\xaa" * (size - HDR_SIZE)


def parse_packet(payload: bytes):
    """Returns (seq, send_sec, send_nsec, size) or None if not a valid packet."""
    if len(payload) < HDR_SIZE:
        return None
    magic, seq, send_sec, send_nsec, size = _STRUCT.unpack(payload[:HDR_SIZE])
    if magic != PKT_MAGIC:
        return None
    return seq, send_sec, send_nsec, size


def latency_ms(send_sec: int, send_nsec: int) -> float:
    now = time.clock_gettime(time.CLOCK_MONOTONIC)
    send_ts = send_sec + send_nsec * 1e-9
    return (now - send_ts) * 1e3
