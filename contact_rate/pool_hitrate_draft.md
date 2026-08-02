# Draft content for connection-pool hit-rate metrics (reviewer ask)

Extends paper.tex's existing `\subsection{Connection-Pool and Link
Behavior Under Load}\label{sec:results-pool}` (Section VI-B in
`paper_section_results_draft.md`), which currently reports *delivery*
under burst vs. paced transmission (Table `tab:burst-paced`) but no
hit-rate figure for the pool itself. This file is intermediate work
product, **not** ready to insert into paper.tex as-is — see "Status" below
before using any of this in the paper.

## Status: instrumentation done, real numbers not obtained

**What's real and working:**

1. `cspcl_conn_pool_get_stats()` (`cspcl/src/cspcl.h`/`cspcl.c`) is now
   reachable from a live, running `unibo-bp-cspcl` process, not just unit
   tests. `cspcl/unibo-integration/src/cspcl_daemon.c` gained a SIGUSR1
   handler (`daemon_stats_signal_handler` sets a flag; the main loop's
   `dump_pool_stats()` reads it) that logs
   `conn_pool stats (SIGUSR1): hits=H misses=M evictions=E
   invalidations=I connect_failures=F hit_rate=R` — also dumped once
   automatically at clean shutdown (`reason="shutdown"`). `unibo-bp-cspcl`
   was rebuilt with this change (`cspcl/unibo-integration/build/unibo-bp-cspcl`,
   using the same `-DCSPCL_*_TIMEOUT_MS=15000` "contact range" build
   DEMO.md's T4 already uses).
2. `contact_rate/measure_pool_hitrate.sh` is written and ready: it
   reuses `test_paced_delivery.sh`'s paced 1024B/4096B scenario, finds
   the running `unibo-bp-cspcl` PID, signals it before/after each size's
   run, diffs the two pool snapshots, and reports hit rate =
   hits/(hits+misses) per size to a markdown table.
3. A Rust FFI wrapper for Hardy's side of the pool (stretch goal) was
   added: `cspcl_conn_pool_get_stats` is already bindgen-generated into
   `cspcl-sys` (matches its `cspcl_.*` allowlist), and a safe wrapper now
   exists at every layer — `cspcl_sys::primitive::conn_pool_get_stats`,
   `cspcl_sys::types::{PoolStats, pool_stats}`, and
   `cspcl::Cspcl::pool_stats()`. **Not wired into the live
   `hardy-bpa-server` binary**: `hardy_cspcl::Cla` exposes
   `try_get_runtime()` on its own concrete type, but
   `hardy-bpa-server/src/config/cla.rs`'s `ClaConfig::build()` returns
   `Arc<dyn Cla>` (a trait object) before `main.rs` ever sees it, so
   there's no hook left to reach the concrete CSPCL instance and its pool
   at runtime without either a downcasting mechanism or a
   registration-side-channel — judged to be the "nontrivial Hardy-side
   architecture change" flagged as out of scope for this pass. The Rust
   API itself is done and tested (`cargo build --release --features
   cspcl` succeeds); only the live-process wiring is left.

**What's missing: an actual measured run.** This work was done in a
sandboxed session with **no root/sudo available** (`sudo` fails
non-interactively with "a password is required" for every command
tried, including trivial ones). That blocks bringing up the real chain
end-to-end:

- `vcan0` (needs `ip link add ... type vcan`, root)
- `alice_ns`/`bob_ns` network namespaces (needs `ip netns add`, root)
- Charon's TUN devices (needs root/`CAP_NET_ADMIN`)
- `tc`/`iptables` link shaping (`shape_links.sh`, root)

All four are required by `measure_pool_hitrate.sh` (and every other
script in this folder — see README, all marked "Root required"). None
of the demo stack was already running (`ps aux` showed no
ud3tn/unibo/hardy/charon processes, and no leftover `vcan0`/netns from
an earlier session), so there was no way to attach to an existing run
either.

**A fallback attempt (also inconclusive):** to still get *some* real
number from the live pool code without root, `contact_rate/pool_bench.c`
was written — a small standalone benchmark (not a unit test) that calls
the real `cspcl_send_bundle()` repeatedly against a real peer process and
reads back `cspcl_conn_pool_get_stats()`. Two transport substitutes for
CAN were tried, in order:

1. **CSP's self-addressed loopback interface** (`csp_if_lo`, single
   process, no root needed at all). Pool bookkeeping worked, but actual
   send+ACK round trips over it were unreliable — RDP handshakes that the
   pool records as successful (`misses` incrementing normally) but that
   then time out waiting for the application-level ACK. This turned out
   to be a known-tolerated quirk, not a bug introduced here: CSPCL's own
   `cspcl/tests/test_cspcl_pool_integration.c` explicitly notes "the send
   may also fail" in a comment and only ever asserts on pool counters,
   never on delivery, for exactly this reason.
2. **CSPCL's `zmqhub` interface** (`cspcl_daemon.c`'s own `-i zmqhub`
   option, documented there as "for testing/ground segment") between two
   real processes bridged by `libcsp/examples/zmqproxy.c` — no root
   needed (unprivileged TCP loopback sockets only). This avoided the
   loopback-specific failure above, but hit a *different* one: repeated
   sends fell into a live RDP retransmission loop (visible directly in
   `zmqproxy`'s own traffic log — a continuous stream of small control
   packets bouncing between the two processes, with no SFP data
   fragments ever going out) that did not resolve even after raising
   `CSPCL_CSP_TIMEOUT_MS`/`CSPCL_ACK_TIMEOUT_MS`/`CSPCL_SFP_TIMEOUT_MS`
   to 15000ms each (the same bump DEMO.md's own "contact range" build
   uses for the real shaped link). Root cause not isolated within the
   time available — candidates include an RDP retransmit-timer/RTT
   mismatch specific to two same-host processes, or something
   `zmqproxy`/PUB-SUB specific (ZMQ PUB/SUB is best-effort and drops
   under some conditions, which could plausibly confuse RDP's state
   machine into this kind of loop). `pool_bench.c` and
   `pool_bench_recv.c` are kept as a documented starting point, not a
   source of numbers — see their header comments.

No numbers in this file are fabricated to fill this gap. There is no
table below because none was measured.

## What to do next (for whoever has root, or more debugging time)

1. Rebuild `unibo-bp-cspcl` if not already current (the SIGUSR1 handler
   is already in `cspcl_daemon.c` and the binary was rebuilt once during
   this pass — just confirm it's newer than the source file).
2. Bring up DEMO.md Phases 1–3 (T1–T9), redirecting T4's
   (`unibo-bp-cspcl`) output to a file, e.g.:
   ```bash
   ./build/unibo-bp-cspcl 1 10 can 2001 /tmp/unibo-node1 \
       > /tmp/unibo-cspcl.log 2>&1 &
   ```
3. `sudo ./contact_rate/measure_pool_hitrate.sh` — reads that log,
   reports hits/misses/evictions/invalidations and hit rate per payload
   size to `<output_dir>/pool_hitrate_report.md`.
4. Fold the resulting numbers into `sec:results-pool` as a short new
   paragraph + a third small table (payload, hits, misses, hit rate),
   after `tab:burst-paced` — the existing "burst vs. paced delivery" text
   already sets up the vocabulary (opportunistic link churn, SFP
   fragments) this would extend.

## A note on what hit rate is likely to show, if/when measured

Worth setting expectations before the real run: `cspcl`'s pool has no
time-based invalidation by default (`max_conn_age_ms` is 0 = disabled in
`cspcl_daemon.c`, confirmed by grep — nothing sets it), and the pool
holds 16 entries (`CSPCL_CONN_POOL_SIZE`) against unibo's single active
downstream peer (hardy) in this topology. With no LRU pressure and no
age-based eviction, the pool-lookup bookkeeping alone should show close
to 100% hits after the first bundle (miss #1, hit for every bundle after
that) for a clean run — the interesting question a real measurement
would actually answer is whether **burst-mode's already-documented
delivery failures** (Table `tab:burst-paced`, 3/10 and 1/10 delivered)
show up on unibo's *sending* side as extra misses/invalidations at all,
or whether they're invisible to this pool entirely because the
send-path failure documented in `sec:results-pool` is attributed to
**hardy → bob's** CSP CLA (µD3TN's opportunistic-link teardown, per the
existing text — bob is the µD3TN node with a CSP CLA; alice's link to
unibo is TCPCLv3, not CSP), not to unibo → hardy. If so, unibo's pool
hit rate would be reported as uniformly high in both burst and paced
modes, and the paper's honest framing would be "the pool's own
bookkeeping is insensitive to the link-churn failure documented above,
because that failure is downstream of unibo's pool, on hardy's link to
bob" — which would itself be a useful, precise clarification of scope
for `sec:results-pool`, if hardy's pool ever gets wired up (stretch goal,
not done) to check the hypothesis directly.
