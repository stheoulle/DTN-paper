# Section 3 benchmark results — raw CSP vs CSP/BP via CSPCL

Final, verified run against `cspcl` branch `fix/connection-handling`
(commit `8015161`) plus three local fixes described in §4. All numbers
below are from `bundle_overhead/results_fixed2/` — a clean, complete
sweep with **zero delivery failures at every N**, in both the burst and
the sustained-streaming test. Design rationale and full methodology are
in `../README.md`; this file reports and interprets the numbers, and §4/§5
are written to be relayed to the branch's author (`duratm`) as a bug
report + patch.

> **Update:** the branch gained a new commit, `d69dc2a` ("refactor:
> express send retry as a bounded loop", `hugoPonthieu`), after this sweep
> was run. It's a pure send-side refactor of the retry-once logic — same
> behavior, no functional change, and it doesn't touch the receive-side
> polling path (§4.1) or `conn_max`/`conn_timeout` handling (§4.3) at all.
> Verified: our fast-poll patch rebases onto it with zero conflicts, and
> the full `ctest` suite still passes 100% on top of it. §4.1's fix is
> still needed and still the only part that touches `cspcl.c` itself.
> Also revised: §4.3's benchmark-side `conn_timeout` workaround moved from
> 300ms to **1000ms** — 300ms turned out to be too tight, since
> `csp_rdp_connect()` (the initial SYN/ACK handshake) uses this exact same
> value as its own connect timeout, not just the CLOSE_WAIT reclaim delay.
> That's a real dual-purpose-knob tradeoff worth the branch author's
> attention too, noted in §4.3/§5.

Run parameters: `CAN_IFACE=vcanbench0`, `TX_ADDR=20`, `RX_ADDR=21`,
`UNIT_SIZE=32` (clamped to **36 bytes** on the wire — `BENCH_HDR_SIZE` in
`common.h`), `N_SWEEP=1 2 4 8 16 32 64`, `BUNDLE_COUNT=30` per N for the
burst test, `STREAM_DURATION_S=10` per N for the streaming test.

## 1. Arm A — raw CSP over CAN (no CSPCL/BP)

| test | sent/recv | delivery | latency min/mean/max (ms) | throughput |
| --- | --- | --- | --- | --- |
| burst (200 pkts, 36B) | 200/200 | 100.0% | 0.022 / 0.066 / 0.460 | 33018.1 pkt/s, 1188.7 kB/s |
| stream (10s, 36B) | 400000 recv | — | 0.008 / 0.026 / 3.378 | 40000.8 pkt/s, 2676.3 kB/s |

Arm A holds one persistent connection with no per-bundle delivery
confirmation beyond RDP's own transport-level ack — it is a fire-and-
send baseline, not a reliability-confirmed one (see §6's caveat on
comparing it against Arm B).

## 2. Arm B — CSP/BP via CSPCL, burst test (30 bundles per N)

All 30/30 bundles delivered at every N (100% delivery, every log).

| N | bundle_len (B) | bundles/sec | units/sec-equiv | kB/s | mean latency (ms) | mean `cspcl_send_bundle()` (ms) |
| --- | --- | --- | --- | --- | --- | --- |
| 1  | 36   | 880.89 | 880.9   | 31.7   | 0.992 | 1.151 |
| 2  | 72   | 876.41 | 1752.8  | 63.1   | 0.957 | 1.133 |
| 4  | 144  | 899.54 | 3598.2  | 129.5  | 1.005 | 1.121 |
| 8  | 288  | 847.64 | 6781.1  | 244.1  | 0.983 | 1.175 |
| 16 | 576  | 875.89 | 14014.2 | 504.5  | 1.027 | 1.147 |
| 32 | 1152 | 814.39 | 26060.6 | 938.2  | 1.067 | 1.256 |
| 64 | 2304 | 880.57 | 56356.4 | 2028.8 | 1.097 | 1.167 |

Flat, stable ~800-900 bundles/sec and ~1-1.3ms latency across the entire
sweep — no N=8 dip, no wild run-to-run variance like earlier iterations
of this benchmark showed. `mean cspcl_send_bundle()` is now dominated by
the CLA-level ACK round trip (a genuine, constant per-bundle cost), not
by reconnection overhead, which is why it's flat rather than scaling with
N the way pure SFP-fragmentation cost would.

## 3. Arm B — CSP/BP via CSPCL, streaming test (sustained load)

Zero `cspcl_send_bundle failed` / `No free connections` errors at any N.

| N | bundle_len (B) | bundles sent/recv | bundles/sec | units/sec-equiv | kB/s | mean unit latency (ms) | max unit latency (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1  | 36   | 8709/8709 | 668.88 | 668.9   | 24.1   | 0.978 | 1.509   |
| 2  | 72   | 8425/8425 | 647.05 | 1294.1  | 46.6   | 1.012 | 4.410   |
| 4  | 144  | 8451/8451 | 649.00 | 2596.0  | 93.5   | 1.016 | 3.259   |
| 8  | 288  | 8351/8351 | 641.34 | 5130.7  | 184.7  | 1.027 | 20.557  |
| 16 | 576  | 8355/8355 | 641.68 | 10266.9 | 369.6  | 1.046 | 20.467  |
| 32 | 1152 | 8072/8072 | 619.95 | 19838.3 | 714.2  | 1.100 | 21.159  |
| 64 | 2304 | 2768/2768 | 212.41 | 13594.5 | 489.4  | 3.501 | 305.761 |

N=64 is the outlier: throughput drops to 212 bundles/sec (vs. ~620-650 at
every other N) and max latency spikes to 306ms, even though delivery is
still 100%. This is the residual effect of the connection-table pressure
described in §4.3 below — occasional retry-triggered reconnects at the
largest, most fragment-heavy bundle size still cost real time (they're no
longer catastrophic, but they're not free either).

## 4. Three issues found and fixed, in order of discovery

This benchmark went through the branch `fix/connection-handling` as
supplied, then two further rounds of investigation once the numbers
didn't look right. All three are described here for a report back to the
branch's author. The full diff against `origin/fix/connection-handling`
is in `bundle_overhead/results/cspcl-rx-fast-poll-fix.patch` (touches only `src/cspcl.c` and
`src/cspcl_config.h`).

### 4.1 Receive-side polling always blocks on accept() first (fixed)

**Symptom:** every send took ~100ms flat, regardless of N, even though
`cspcl_send_bundle()`'s own measured compute time was sub-millisecond.

**Cause:** `cspcl_recv_bundle()` calls `cspcl_accept_conn(..., accept_timeout)`
on *every* call to check for new inbound connections, even when a live
connection already has a bundle ready to read. `accept_timeout` is capped
at `CSPCL_RX_ACCEPT_POLL_MS` (100ms), and libcsp's `csp_accept()` blocks
for the *entire* timeout via a blocking queue-dequeue when no new peer is
connecting — which, after the first bundle, is always true (the sender
reuses one connection). So every receive call paid a mandatory ~100ms tax
waiting on a connection nobody was opening, before ever checking the live
connection that already had data.

**Fix:** added `cspcl_rx_poll_once()` (factored out of the existing
round-robin poll loop) and call it in a short retry loop *before* the
accept-wait, using repeated 0ms (non-blocking) reads with 1ms sleeps in
between, for a total budget of `CSPCL_RX_FAST_POLL_BUDGET_MS` (new
constant, default 20ms). A single 0ms check was tried first and found
insufficient — if the bundle is only microseconds from arriving, one
failed check falls all the way through to the accept-wait anyway, and
because the peer is waiting for this call to return before sending its
next bundle, that one slow round trip re-paces every subsequent call to
land just *before* the next bundle arrives too, making the accept-wait
path self-sustaining rather than a one-off. Retrying within a small budget
breaks that resonance. (A nonzero timeout can't be passed directly to
`csp_read()` here either: on an RDP connection any nonzero value below
`conn->rdp.conn_timeout` is silently clamped *up* to it — several seconds
by default — so the retry has to be built from repeated 0ms polls, not a
single non-zero-timeout read.)

### 4.2 Connection-reuse regression this branch already fixes (verified, no change needed)

The branch's own core fix — invalidate the pooled connection only on send
failure, not after every send, and have the receiver keep accepted
connections open across calls (`CSPCL_RX_CONN_TABLE_SIZE`-entry table,
round-robin polled, LRU-evicted) — works correctly and was the reason we
switched to this branch in the first place. No changes needed here; it's
listed for completeness in the report.

### 4.3 Connection-table exhaustion under sustained load at large N (fixed, benchmark-side)

**Symptom:** long streaming runs at N=64 (2304B bundles, 10 SFP fragments
each) eventually failed outright with `No free connections, max 28` and
stopped sending entirely (as few as 34-292 bundles before total failure,
inconsistent run to run).

**Cause:** `csp_conf.conn_max = CSPCL_CONN_POOL_SIZE + CSPCL_RX_CONN_TABLE_SIZE + 4 = 28`
on this branch. The happy path (reused, still-open connection) never
touches this table after the first connect/accept — but
`cspcl_send_bundle()`'s retry-once-on-failure path still calls
`csp_close()` on a connection when a send fails, and a closed RDP
connection holds its table slot through `RDP_CLOSE_WAIT` for
`conn_timeout` (10s default, `libcsp/src/transport/csp_rdp.c`) before
being reclaimed. At N=64, more SFP fragments per bundle means more chances
for an occasional timing hiccup to trip a send failure; under sustained
load, enough of these accumulate within one 10-second `conn_timeout`
window to exhaust all 28 slots, even though the overwhelming majority of
sends never hit this path. This is the same underlying libcsp behavior as
the original ephemeral-port-exhaustion bug this branch was written to fix
— just gated by "occasional failures" instead of "every single send," so
it only shows up under sustained load at the larger, more fragment-heavy
end of the N sweep.

**Fix (applied in the benchmark tool, not in `cspcl.c` itself — see
`bundle_overhead/csp_stack.c`):** `csp_rdp_set_opt(4, 1000, 1000, 1, 250, 2)`
right after `cspcl_init()`, dropping `conn_timeout` from 10000ms to 1000ms.
This only affects how long a *closed* connection's slot is held, not the
happy path's reused, still-open connection, so it's safe to apply without
touching `cspcl.c`. **Caveat found afterward:** `conn_timeout` is a
dual-purpose knob — `csp_rdp_connect()` (`libcsp/src/transport/csp_rdp.c:905`)
also uses this exact value as how long a brand-new connection waits for
the peer's SYN/ACK before giving up. An initial attempt at 300ms was too
aggressive: under system load it sometimes wasn't enough time for the
handshake itself, causing new connections to fail outright (silently —
`csp_rdp_connect()`'s own timeout path only logs at
`CSP_LOG_LEVEL_PROTOCOL`, so nothing appears in normal error/warn output).
1000ms is a more realistic balance. Worth the branch author's attention:
splitting "connect timeout" from "CLOSE_WAIT reclaim timeout" into two
independent knobs would remove this tradeoff entirely. After settling on
1000ms, N=64's streaming run completed with 100% delivery and no further
connection-table exhaustion (§3), though its throughput (212 bundles/sec)
and latency variance (up to 306ms) still
show the residual cost of the occasional retry — worth the branch author
investigating why sends occasionally fail at all under sustained load at
large N, since a lower failure rate would remove the remaining slowdown
too.

## 5. Recommended patch for the dev

- `cspcl.c`/`cspcl_config.h`: the fast-path retry-loop fix in §4.1 (full
  diff in `bundle_overhead/results/cspcl-rx-fast-poll-fix.patch`) — this is a real bug in the
  branch as supplied, independent of which ack mechanism is used (verified
  against both the CLA-ack tip and the pre-ack-switch commit `d00d241`
  with the `libcsp-rdp-peer-timeout.patch` applied).
- Worth deciding upstream whether `conn_timeout` should default lower than
  10s given how it interacts with `conn_max`, or whether `conn_max` should
  scale with expected failure rate under load — the fix in §4.3 was applied
  benchmark-side as a workaround, not as a `cspcl.c` change, since it's a
  tuning tradeoff (shorter `conn_timeout` also means less tolerance for a
  genuinely slow-but-alive peer) that the branch author should own.
- Separately worth investigating: *why* sends occasionally fail at all
  under sustained load at large N (the trigger for §4.3's retry path) —
  fixing that would likely also fix the N=64 throughput/latency dip in §3.

## 6. Analytic memory overhead (RFC 9171-derived, unaffected by any of the above)

`overhead_table.py`'s `bp7_bundle_overhead_bytes()` derives the exact CBOR
byte count of a minimal BP7 bundle field-by-field from RFC 9171 (§4.1
indefinite-array framing, §4.3.1 8-item primary block, §4.2.5 `ipn`/
`dtn:none` EID encoding, §4.3.2 5-item payload block, RFC 8949 CBOR integer
sizing), using this benchmark's real addressing (node 20/21, service 10 =
`CSPCL_PORT_BP`). Purely about wire bytes, not connection handling, so
unaffected by anything in §4:

| N | bundle_len | fragments | CSPCL ovh (B) | BP7 ovh (B) | total ovh (B) | overhead % |
| --- | --- | --- | --- | --- | --- | --- |
| 1  | 36   | 1  | 13  | 42 | 55  | 152.78% |
| 2  | 72   | 1  | 13  | 42 | 55  | 76.39%  |
| 4  | 144  | 1  | 13  | 42 | 55  | 38.19%  |
| 8  | 288  | 2  | 26  | 43 | 69  | 23.96%  |
| 16 | 576  | 3  | 39  | 43 | 82  | 14.24%  |
| 32 | 1152 | 5  | 65  | 43 | 108 | 9.38%   |
| 64 | 2304 | 10 | 130 | 43 | 173 | 7.51%   |

- **N ≤ 4** (single SFP fragment): CSPCL's own framing is flat at 13B;
  falling overhead% is purely BP7's fixed ~42B header amortized over a
  growing payload.
- **N ≥ 8** (multi-fragment): CSPCL's per-fragment 13B accumulates (26B at
  N=8 up to 130B at N=64) and becomes the dominant term, while BP7 stays
  flat at 42-43B.
- **Caveat:** this benchmark calls `cspcl_send_bundle()` directly,
  bypassing a full BPA, so the BP7 figure is derived from RFC 9171's CBOR
  rules, not measured off the wire. Assumes no extension blocks, no CRC.

## 7. Other caveats

- **Arm A vs Arm B is not a like-for-like reliability comparison anymore.**
  Arm B (CSPCL/BP) now waits for a CLA-level application acknowledgment
  confirming actual bundle delivery before `cspcl_send_bundle()` returns
  — a real, valuable guarantee, but also a real, unavoidable extra round
  trip. Arm A (raw CSP) has no equivalent per-packet confirmation. Some of
  the throughput gap between the two arms in this data reflects that extra
  guarantee, not pure protocol framing overhead — keep that framing in
  mind before quoting a "CSPCL is Nx slower than raw CSP" number without
  the context that CSPCL is also proving delivery and raw CSP here is not.
- `vcanbench0` is a virtual CAN interface with no real bandwidth throttling
  — absolute pkt/s and kB/s numbers aren't directly comparable to the
  paper's modeled 50/100 kbps contact rates. The memory-overhead ratios in
  §6 remain valid regardless of link speed.
- These results come from calling `cspcl_send_bundle()`/`cspcl_recv_bundle()`
  directly, not from routing a bundle through a full BPA. Extending this to
  the actual 4-BPA chain is a distinct, not-yet-started follow-up (see
  `../zAIE.md`).
- **`vcanbench0` is shared with other traffic on this machine.** While
  re-verifying this fix against the branch's newest commit, `candump`
  showed sustained, high-volume CSP traffic on `vcanbench0` using addresses
  9-11 — not this benchmark's 20/21 — from some other process/terminal on
  the same machine. That contention caused repeated, otherwise-unexplained
  `cspcl_send_bundle` connect failures (confirmed via full RDP protocol
  tracing: our SYN was sent and retransmitted 9 times with zero reply,
  while raw CSP on the same interface worked fine when tested in
  isolation). This is external to all three fixes in §4 — before trusting
  any single benchmark run's numbers (especially a failure), check
  `candump vcanbench0` first for unrelated traffic, or use a dedicated vcan
  interface not shared with any other process.
