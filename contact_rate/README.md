# contact_rate — achieved throughput vs. the modeled 50/100 kbit/s contact rates

Answers `paper_comments.md`'s "achieved throughput against the modeled
50/100 kbps contact rates" item, end-to-end across the real 4-hop demo
chain (alice → unibo → hardy → bob).

## Why this didn't already exist

`demo/alice.cp`'s contact plan (`contact 1 2 0 9999999999 50000 5`, etc.)
and `unibo-bp-admin contact add --xmit-rate 50000` are both routing-only
metadata — consumed by the BPAs' contact-graph routing logic (predicted
arrival times, route selection), not enforced as a real bandwidth limit
anywhere. `vcan0` and the alice↔unibo TCP connection both currently run at
full, unconstrained speed regardless of what the contact plan says. This
folder makes those numbers real and measures against them.

## Files

- **`check_tc_vcan.sh`** — run this first. Validates that `tc qdisc ...
  tbf` actually throttles a virtual CAN interface (this is not something
  to assume — `tc` is overwhelmingly validated against IP traffic, not CAN
  frames, and vcan has no real bus arbitration). Creates a throwaway
  interface (never touches `vcan0`), times a fixed burst of traffic
  unshaped vs. shaped, and reports PASS/WARN/FAIL. **Root required.**
- **`shape_links.sh up|down [can_kbps] [tcp_kbps]`** — applies/removes the
  real shaping: a `tc tbf` qdisc on `vcan0` (both CAN hops share that one
  bus) at `can_kbps` (default 50, matching `alice.cp`), and a `tc prio` +
  `tbf` + `iptables CLASSIFY` setup on loopback ports 4224/4225 (TCPCLv3,
  alice↔unibo) at `tcp_kbps` (default 100). **Root required.** The
  loopback shaping is less consistently reliable across kernels than
  shaping a real interface — if the alice↔unibo numbers ever look
  implausible (near-unshaped), verify manually before trusting them; the
  CAN-hop shaping is the well-validated half (see `check_tc_vcan.sh`).
- **`ceiling.py`** — the theoretical throughput ceiling calculator, no
  root needed. For the CAN hops, derives the *exact* CBOR byte count of
  BP7 framing (same RFC 9171 derivation as
  `bundle_overhead/overhead_table.py`), CSPCL/SFP fragmentation, the CSP
  header, libcsp's CAN Fragmentation Protocol (CFP) overhead, and raw
  extended-ID CAN 2.0B frame overhead bit-for-bit (67 fixed bits/frame
  before data). For the alice↔unibo hop, uses an approximate TCPCLv3 +
  TCP/IP overhead model (documented as an estimate in the source — this
  hop is never the binding constraint at 2x the CAN hops' nominal rate,
  so it doesn't need CAN's level of rigor). Run standalone:
  `python3 ceiling.py --sweep 64 256 1024 4096`.
- **`run_contact_rate_measure.sh [output_dir]`** — the orchestrator.
  Shapes the links, reuses `apps/sender`/`apps/receiver` (the same
  binaries `apps/measure.sh` drives) to burst each payload size through
  the real netns/Charon/BP chain, computes the ceiling for that size via
  `ceiling.py`, and reports achieved throughput as a percentage of it.
  Always un-shapes the links on exit, including on error. **Root
  required.** Env overrides: `CAN_KBPS`, `TCP_KBPS`,
  `SIZES="64 256 1024 4096"`, `COUNT`. Per-size receive timeout is
  computed automatically from `ceiling.py`'s per-bundle time estimate, not
  a fixed value — see the script's header comment.
- **`test_paced_delivery.sh [output_dir]`** — confirms 1024B/4096B bundles
  are delivered reliably (COUNT/COUNT) when paced instead of streamed, per
  "Connection churn under back-to-back multi-fragment bundles" below, and
  reports achieved throughput against the same ceiling model
  `run_contact_rate_measure.sh` uses. Elapsed time for the throughput
  figure is anchored to `vcan0`'s own `tc -s qdisc show` backlog draining
  to zero, not to `apps/receiver`'s own completion signal — the latter has
  been observed reporting paced multi-fragment bundles "delivered" before
  the qdisc has actually finished draining them, for a reason not yet
  isolated; see the script's header comment. **Root required.** Env
  overrides: `CAN_KBPS`, `TCP_KBPS`, `SIZES="1024 4096"`, `COUNT`,
  `PACE_MARGIN`.
- **`measure_resource_usage.sh [output_dir]`** — CPU% and RSS of the six
  persistent relay/BPA processes in the real chain (alice's uD3TN, bob's
  uD3TN, `unibo-bp-cspcl`, `hardy-bpa-server`, and the two `charon`
  instances), sampled every 0.5s (`ps -o %cpu,rss -p <pid>`) while
  `apps/sender` bursts each payload size through the chain, same
  send/receive pattern as `run_contact_rate_measure.sh`. PIDs are resolved
  once via `pgrep -f` on a substring unique to each process's launch
  command (verified unique at resolve time — aborts loudly if a pattern
  matches zero or more than one process). Reports mean/peak %cpu and peak
  RSS per process per payload size to
  `<output_dir>/resource_usage_report.md`. `ps %cpu` is a kernel/procps-
  smoothed decaying average, not an instantaneous per-sample reading —
  see the script's header comment for why that tradeoff was chosen over
  `/proc/<pid>/stat` deltas, and for the single-core-relative (not
  `nproc`-normalized) %cpu convention. **Root required.** Env overrides:
  `CAN_KBPS`, `TCP_KBPS`, `SIZES="64 256 1024 4096"`, `COUNT`,
  `SAMPLE_INTERVAL_S`.
- **`measure_pool_hitrate.sh [output_dir]`** — connection-pool hit-rate
  metrics for `unibo-bp-cspcl`'s outbound pool (node1's link to hardy),
  under the same paced 1024B/4096B scenario `test_paced_delivery.sh`
  uses. Depends on a SIGUSR1 handler added to
  `cspcl/unibo-integration/src/cspcl_daemon.c` (`daemon_stats_signal_handler`
  / `dump_pool_stats`) that calls the real `cspcl_conn_pool_get_stats()`
  accessor and logs one `conn_pool stats (...): hits=.. misses=..
  evictions=.. invalidations=.. connect_failures=.. hit_rate=..` line —
  this script finds the running `unibo-bp-cspcl` PID via `pgrep`, signals
  it before and after the send, and diffs the two snapshots read back
  from its log file (the daemon's pool is long-lived and shared across
  every run against it, so an un-diffed read would include earlier
  runs' traffic). **Root required.** Needs `unibo-bp-cspcl` rebuilt
  after the SIGUSR1 handler was added (see DEMO.md T4) and its stderr
  redirected to a file (`UNIBO_LOG`, default `/tmp/unibo-cspcl.log`).
  Env overrides: `CAN_KBPS`, `TCP_KBPS`, `SIZES="1024 4096"`, `COUNT`,
  `PACE_MARGIN`, `UNIBO_LOG`, `UNIBO_PID_PATTERN`. **Not yet run
  end-to-end**: written and rebuilt in a sandboxed session with no
  root/sudo, so it could not actually be exercised against the real
  chain — see `pool_hitrate_draft.md` for what was and wasn't validated.
- **`pool_bench.c` / `pool_bench_recv.c`** — a from-scratch, root-free
  fallback attempt at a live (non-unit-test) pool benchmark, written when
  `measure_pool_hitrate.sh` above couldn't be run for lack of root. Both
  compile and link cleanly against `cspcl/src/cspcl.c` and exercise the
  real `cspcl_send_bundle()` / connection-pool code — first over CSP's
  self-addressed loopback interface, then (after that proved unreliable
  in this environment, see `pool_bench.c`'s header) over CSPCL's
  `zmqhub` interface between two real processes bridged by
  `libcsp/examples/zmqproxy.c`. The zmqhub attempt also did not reach a
  trustworthy result: `csp_connect()` between the two processes fell
  into a live RDP retransmission loop that persisted even with
  `CSPCL_CSP_TIMEOUT_MS`/`CSPCL_ACK_TIMEOUT_MS`/`CSPCL_SFP_TIMEOUT_MS`
  raised to 15000ms, and the root cause wasn't isolated. Kept as a
  starting point for whoever picks this up next (either with root, to
  just run `measure_pool_hitrate.sh` instead, or to debug the
  RDP/zmqhub issue directly) — not a validated source of numbers as-is.

## Usage

```bash
# 1. Confirm tc actually shapes vcan traffic on this machine/kernel
sudo ./check_tc_vcan.sh 50

# 2. Full stack up per DEMO.md Phase 1-3 (T1-T9) -- see "CSPCL protocol
#    timeouts" below before building unibo/hardy/bob if you're testing
#    1024B/4096B payloads -- then:
sudo ./run_contact_rate_measure.sh results_50_100
```

## Connection churn under back-to-back multi-fragment bundles

At 1024B/4096B payloads sent back-to-back (burst mode, 0ms interval),
real bundle loss (not just measurement-window truncation) shows up:
delivery stays at ~3/10 and ~1/10.

**Ruled out:** CSPCL's internal protocol timeouts (`CSPCL_CSP_TIMEOUT_MS`,
`CSPCL_ACK_TIMEOUT_MS`, `CSPCL_SFP_TIMEOUT_MS`, all `#ifndef`-guarded in
`cspcl_config.h`) firing too early on the shaped link was the first
hypothesis -- rebuilding unibo/hardy/bob with all three bumped to 15000ms
(15x default) and rerunning changed nothing, still ~3/10 and ~1/10. So
this isn't a timeout tuned for the wrong link speed.

**Actual root cause:** it's specifically about bundles arriving close
together, independent of any timeout value -- a single isolated 1024B/4096B
send always succeeds. uD3TN's CSP CLA (`components/cla/posix/cla_csp.c`)
manages an "opportunistic" link per peer that tears itself down and
removes its hash-table entry as soon as it goes idle
(`csp_link_management_task`'s cleanup path); the next arriving fragment
then re-triggers `launch_connection_management()` from scratch as if it
were a brand-new peer. When bundles are sent back-to-back, this
teardown/recreate cycle lands in the middle of a still-in-progress
SFP-fragmented transfer, corrupting reassembly on the receiving node --
visible as repeated `Starting link management for csp:N` restarts
alongside `csp_sfp_recv_fp: invalid message, offset 243 (expected 0)`
(243 = `CSPCL_MAX_PAYLOAD`, i.e. a second fragment arriving with no
matching first fragment because the link session that carried it was
torn down mid-transfer).

**Validated mitigation:** pacing. Spacing sends out (e.g. 500ms apart for
1024B) gives each link session time to complete before the next begins --
confirmed 10/10 delivery where the same payload at 0ms interval got 3/10.
`test_paced_delivery.sh` (below) is the regression check for this.

This is a real limitation in uD3TN's opportunistic-link handling, not
something fixable from this benchmark's side -- fixing it properly means
changing `cla_csp.c` itself (out of scope for now). For the paper, this
is a legitimate characterization of connection-pool behavior under load
(a named reviewer ask), not just a benchmark quirk: single-fragment
payloads (≤`CSPCL_MAX_PAYLOAD` = 243B, i.e. 64B/256B here) are unaffected
regardless of pacing; multi-fragment payloads need pacing to avoid
link-churn-induced loss.

Output: a table (and `results_50_100/contact_rate_report.md`) of achieved
kB/s, the computed ceiling, and % of ceiling achieved, per payload size —
the "X% of theoretical capacity achieved" figure `paper_comments.md`
asks for, instead of a raw kB/s number with nothing to compare it against.

## Design notes

- **Why shape `vcan0` once, not per-hop**: unibo↔hardy and hardy↔bob are
  the *same physical bus* (both CSPCL endpoints sit on `vcan0`), so one
  `tbf` qdisc on the interface covers both hops identically, matching
  `alice.cp`'s equal 50 kbit/s rate for each.
- **Why the end-to-end ceiling isn't just the slowest hop's rate**: the
  chain is serial store-and-forward (a bundle must fully arrive at each
  node before being forwarded), not a pipeline, so `ceiling.py` sums
  transmission *time* across all three hops (2× the CAN hop time + 1× the
  TCP hop time) rather than reporting a single hop's rate.
- **What's rigorous vs. approximate**: the CAN-hop ceiling is derived
  bit-for-bit from RFC 9171, CSPCL's own header constants, and libcsp's
  actual CFP/CAN framing code — nothing assumed. The TCP-hop ceiling uses
  an estimated TCPCLv3 segment header size (not verified against the
  uD3TN/Unibo-BP source) — fine given it's never the binding constraint,
  but worth tightening if that hop's number specifically needs to go in
  the paper.
- **Bit-stuffing**: `ceiling.py --stuffing-margin` defaults to `1.0`
  (best-case, no stuffing). Real CAN buses commonly see ~10-20% additional
  overhead from bit-stuffing depending on data patterns; pass e.g. `1.2`
  for a worst-case estimate instead of the best-case default.
