# Comments on the Paper

If you can do a small throttle text on the CSP to get a volume per second metric, this would be great

All of this needs to happen using the disrupt.sh but commenting the disruption part to keep only the eval of the latency.

Having an overhead eval of raw CSP vs BP/CSPCL
The idea is having
charon CSP over BP/CSPCL versus raw CSP
Or IP over charon/BP(CL?) vs IP

throughput, latency, and CPU load across the different BPAs

small set of benchmarks would help readers understand the practical cost of layering BP over CS

achieved throughput against the modeled 50/100 kbps contact rates

---

## Detailed measurement protocol

Status legend: **[done]** tooling already exists and just needs to be run / logged for the
paper, **[gap]** nothing currently isolates this and new tooling is needed, **[extend]**
existing tooling needs a small addition.

### 1. End-to-end latency & throughput sweep — [done], run it

`apps/measure.sh` already sweeps payload sizes (64/256/1024/4096 B by default) across the
full 4-hop chain (alice → unibo → hardy → bob) and reports delivered count, min/mean/max
latency, and throughput per size. This is the base dataset for the paper's Section V
results table.

To use it directly for the "achieved throughput against the modeled 50/100 kbps contact
rates" comment: add a reference column to the output table (or the post-processing step)
with the **theoretical ceiling** for each hop combination, since the contact plan
(`demo/alice.cp`) models:

- alice→unibo: 100 kbps (TCP segment, negligible OWLT)
- unibo→hardy and hardy→bob: 50 kbps each (CAN, 5 ms OWLT)

The end-to-end path is capacitated by the slowest hop (50 kbps CAN), so the honest
ceiling to quote against measured throughput is ~50 kbps minus BP7 primary/extension
block overhead, CSPCL/SFP fragmentation overhead, and CSP header overhead (4 bytes/CSP
packet, chunked at the CAN MTU of ~8 bytes payload per frame). Worth computing that
ceiling explicitly (bytes of protocol overhead per application byte, at each payload
size in `SIZES`) so the paper can say "X% of theoretical capacity achieved" rather than
just a raw kB/s number.

Action: run `sudo ./apps/measure.sh`, keep the raw per-packet logs, and compute the
overhead-adjusted ceiling per size class for the results table.

### 2. Store-and-forward disruption test — [done], already in the shape asked for

`apps/disrupt.sh` sends a fixed packet stream across the chain. The disruption
window (link down at t=3s for 10s, lines 64–74) is **already commented out**, so the
script currently runs as a pure connectivity + latency measurement (matches the comment
"commenting the disruption part to keep only the eval of the latency").

Two runs are needed from the same script, controlled by that comment block:

1. **Latency-only run** (current state, disruption commented): reports per-packet
   latency with the link always up — this is the "connectivity validation" baseline the
   reviewers already noted the paper needs quantified (Section V-B admits "no scheduled
   disruptions").
2. **Disruption run** (uncomment lines 64–74): demonstrates the store-and-forward
   PASS/PARTIAL verdict, i.e. the actual DTN capability reviewers said was untested.

Both runs' logs should be kept — the first feeds the latency table, the second is the
qualitative "recovers from a 10 s link interruption" claim, directly answering Review 2's
"add at least one disruption scenario" request.

### 3. Overhead: raw CSP vs CSP/BP(CSPCL) — [done], implemented in `bundle_overhead/`

**Manager clarification: the sweep variable is bundle granularity (number of CSP packets
per bundle), not application payload byte size.** The two arms:

- **Arm A — raw CSP over CAN, no CSPCL/BP/Charon at all.** A minimal `csp_sender` /
  `csp_receiver` pair (analogous to `apps/sender.c`/`apps/receiver.c`, but using
  `libcsp`'s socket API directly) sending fixed-size CSP packets back to back over the
  same `vcan0` interface used by unibo↔hardy today. Report **CSP packets/sec** as the
  headline metric (this is the "Nb paquets csp/sec" ask), plus the equivalent kB/s.
- **Arm B — the same CSP packets carried inside BP bundles via CSPCL, over the same CAN
  link.** Sweep **N = number of CSP packets aggregated into one bundle** (e.g.
  N = 1, 2, 4, 8, 16, 32...), holding the CSP packet size fixed. This isolates BP7 +
  CSPCL framing/processing cost as a function of *how much is batched per bundle*,
  independent of the underlying CSP/CAN transport, which is identical in both arms.

Expected shape (per the manager: "bundle petit = overhead important"): overhead is large
at N=1 (full BP7 primary/extension block + CSPCL bookkeeping paid for a single CSP
packet's worth of payload) and shrinks as N grows and the fixed per-bundle cost is
amortized over more CSP packets.

Overhead must be reported in **two units, not just wall-clock latency**:

- **memory**: bytes of BP7 + CSPCL framing overhead per useful CSP payload byte, as a
  function of N (static, computable from header sizes, but worth confirming against
  actual bundle sizes on the wire),
- **compute time**: measured encode/decode/dispatch time per bundle at each N (e.g.
  wrap `cspcl_send_bundle()` / bundle-receive path with `clock_gettime` around the
  CSPCL/BP7 (de)serialisation step, not the network I/O).

**Streaming variant** (separate from the single-bundle-at-a-time test above): instead of
sending N packets once and stopping, stream a sustained volume of CSP traffic
continuously through Arm A and Arm B, again sweeping N for Arm B. This measures whether
BP layering costs more (relatively) under sustained load than in a one-shot exchange —
i.e. the overhead *rate* (throughput lost to BP framing) rather than the overhead
*per bundle*. Same two arms, same N sweep, but the metric is sustained kB/s (and
packets/sec) delivered, not per-bundle latency.

Comparison point: Arm A (raw CSP, packets/sec + kB/s) vs Arm B (CSP/BP via CSPCL) at each
N, for both the single-bundle test and the streaming test. The delta at each N is the
quantified "practical cost of layering BP over CSP" the reviewers asked for, expressed as
a function of bundle size as the manager specified — not as a function of raw payload
size as originally drafted.

**Implementation**: `bundle_overhead/` — four C binaries (`csp_raw_sender`/
`csp_raw_receiver` for Arm A, `bundle_sender`/`bundle_receiver` for Arm B, the
latter linking the real `cspcl_send_bundle()`/`cspcl_recv_bundle()`, not a
synthetic stand-in), an analytic memory-overhead calculator
(`overhead_table.py`), and a driver script (`run_bundle_overhead.sh`) that
runs both the single-bundle and streaming variants across the N sweep and
prints a consolidated table. See `bundle_overhead/README.md` for the full
design and how to run it (needs a SocketCAN/vcan interface; not yet run live
in this session — root is required to create the vcan interface first).

### 4. Overhead: IP over Charon/BP vs raw IP — [gap], needs a baseline run

Symmetric case at the Charon layer: `apps/sender.c`/`receiver.c` already exercise
IP-over-Charon-over-BP end-to-end (that's what `measure.sh` runs today). What's missing
is the **raw-IP baseline**: same two hosts, same `sender`/`receiver` binaries, but talking
directly over a plain link (e.g. a veth pair or the raw Ethernet segment) with no TUN,
no Charon, no BP in between. Since `sender.c`/`receiver.c` are already transport-agnostic
UDP tools, this baseline needs no new code — just a topology without Charon/DTN in the
loop, using the same `SIZES`/`COUNT` parameters as `measure.sh` for a like-for-like
comparison.

Comparison point: `measure.sh` (App→Charon→BP chain→Charon→App) vs this raw-IP baseline.
The delta quantifies Charon's tunneling overhead specifically, separate from the
CSPCL/BP overhead measured in item 3.

### 5. CPU load across BPAs — [gap], needs a sampling wrapper

No current script samples CPU usage per process. Needed: a small wrapper (e.g.
`apps/cpu_monitor.sh`) that, for the duration of a `measure.sh` or `disrupt.sh` run,
samples `/proc/<pid>/stat` (or shells out to `pidstat -p <pid> 1`) for each of the
BPA processes — `ud3tn` (alice), `unibo-bp` + `unibo-bp-cspcl` daemon (unibo),
`hardy-bpa-server` (hardy), `ud3tn` (bob) — and logs mean/max %CPU per node over the
run. PIDs can be captured from the DEMO.md T1/T3/T3b/T5/T6 terminals (or recorded to a
pidfile when each component is launched) and passed to the monitor script alongside the
measurement run.

Output needed for the paper: one row per BPA (alice/unibo/hardy/bob) with mean/max %CPU,
aligned against the same payload-size sweep as `measure.sh`, to support the "CPU load
across the different BPAs" ask.

### 6. Consolidated results table for the paper

Once items 1–5 are run, the Section V results table should report, per payload size and
per hop-pair where relevant:

- end-to-end latency (min/mean/max) — from `measure.sh`
- CSPCL/BP overhead vs raw CSP, per bundle granularity N, single-bundle and streaming,
  in packets/sec, memory, and compute time — from item 3
- Charon/BP overhead vs raw IP — from item 4
- per-node CPU load — from item 5
- store-and-forward recovery verdict — from `disrupt.sh` disruption run (item 2) (on dit que ça marche mais pas à mettre dans le becnhmark)

This directly closes the "no quantitative results reported anywhere" gap both reviewers
raised, using the instrumentation already built (`sender.c`/`receiver.c`, `measure.sh`,
`disrupt.sh`) plus the three additions above (raw-CSP/bundle-granularity baseline,
raw-IP baseline, CPU sampling).
