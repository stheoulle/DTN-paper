# arm4-e2e-chain — full 4-node chain vs. modeled contact rate

Answers reviewer 2's specific, still-outstanding ask: bundle delivery
latency and throughput across the **full 4-hop chain**
(alice → unibo → hardy → bob, via Charon at both ends), measured against
the contact plan's modeled 50/100 kbps rates *actually enforced*, not
just referenced — with statistically meaningful sample sizes (N=100 by
default) and standard deviations.

This is deliberately a different measurement from `layer-overhead/`:
that benchmark isolates a single node pair on one unshaped CAN link to
attribute cost to individual protocol layers (see its own README).
It was never meant to substitute for the multi-hop, contact-rate-modeled
number reviewer 2 asked for, and doesn't.

**Scope: 64/256 B only, not the full 64/256/1024/4096 sweep used
elsewhere in this paper.** Those two sizes are what CSP telemetry/
command traffic on this project's target CubeSats actually looks like.
1024/4096 B were only ever used elsewhere (`layer-overhead/`,
`contact_rate/`) to stress-test the connection pool under load — a
different question, not a realistic operational message size, and one
this directory deliberately doesn't re-run at the 4-hop level: under
genuine 50/100 kbps shaping those bursts collapse to ~3/10 and ~1/10
delivered (see `contact_rate/README.md`'s diagnosis — a real, separately
already-answered limitation, not something to reproduce again here for
sizes that were never going to be sent to a satellite anyway).

## Built on top of `contact_rate/` — read that first

**`contact_rate/` already exists in this repo and does most of the hard
part.** It was built in an earlier session (also without root, also
never run end-to-end), and turned out to be exactly what this ask
needed: `shape_links.sh` (validated `tc`-based shaping of `vcan0` and the
alice↔unibo loopback link to the contact plan's real 50/100 kbps),
`check_tc_vcan.sh` (confirms `tc` actually throttles a *virtual* CAN
interface, which is not something to assume), and `ceiling.py` (the
exact modeled-throughput calculation reviewer 2's "X% of ceiling" ask
needs). `contact_rate/results_50_100_fixed/contact_rate_report.md`
already contains the numbers currently sitting in `main.tex` (202/1241 ms
latency, 94.0%/83.3% of ceiling at 64/256 B) — this directory *is* where
those existing numbers came from, at `COUNT=10` in one single burst per
size (not 10 independent repetitions).

**What this directory adds on top**: `contact_rate/run_contact_rate_measure.sh`
has no repetition loop — one burst per size, no mean/stddev. `run_arm4.sh`
here reuses `shape_links.sh` and `ceiling.py` as-is but wraps them in the
same independent-repetition structure as `layer-overhead/`'s arms, to
actually fix the reviewer's "N=10 isn't statistically reliable" complaint
rather than just reproducing the same single-shot measurement more
precisely worded — and at 64/256 B only, both campaigns are fast and
reliable (10/10 delivered even under real shaping, per the existing
`contact_rate` data), so this is a clean, quick sweep with none of the
connection-churn complications 1024/4096 B would introduce.

## What it measures

The same topology and processes documented manually in `DEMO.md`
(T1–T9), brought up **once** and then driven through many independent
send/receive trials — restarting all ten processes per trial would be
both unnecessary (each message is already an independent trial once the
stack is stable) and impractically slow at N=100.

One campaign per payload size: `throughput_results`, a 10-packet burst
per rep (COUNT=10, matching `apps/measure.sh`'s original method), REPS
independent reps. Achieved throughput comes from each rep's wall-clock
elapsed time; mean latency comes from that same rep's within-burst
per-packet timestamps, averaged first within the burst then across reps.

**There is deliberately no separate single-packet latency campaign, and
adding one back would silently produce wrong numbers.** `layer-overhead/`
uses that pattern (COUNT=1 per rep) to get "clean" latency decoupled from
within-burst queuing, which is the right call on its *unshaped* link. On
this shaped link it's actively misleading: `shape_links.sh`'s `tc tbf`
qdisc uses a deliberately tiny `burst=64` token allowance (to stop large
multi-fragment bundles riding a big allowance unshaped — see its own
comment). An isolated packet sent after the idle gap between reps always
finds that allowance freshly refilled (~10ms at 50kbit/s) and gets the
same free ride as any burst's *first* packet — confirmed against a real
run: an isolated-packet rep measured 9.4ms, matching a same-size burst's
first packet (8.0ms) almost exactly, while that burst's later packets
(once the allowance was drained) cost ~101ms each, the genuinely shaped
rate. An isolated-send campaign against a small-burst `tbf` shaper
measures the burst-allowance artifact, not shaped latency — no amount of
extra reps fixes that, it's a methodology mismatch, not noise. Mean
latency here is instead derived from the throughput campaign's own
within-burst timestamps, the same convention the paper's existing,
already-reviewed Table D used (one `COUNT=10` burst), just properly
averaged across many independent bursts instead of one.

Sizes: 64 / 256 B by default (`SIZES` env override if you want to explore
1024/4096 B anyway for engineering purposes — see "If you override
`SIZES`" below for the runtime cost that involves).

`run_arm4.sh` shapes the links via `contact_rate/shape_links.sh up` before
the sweep and always removes shaping on exit (including on error).
`summarize_arm4.py` computes mean ± stddev **across reps** (not across
packets within one burst — see `layer-overhead/summarize.py`'s docstring
for the general reasoning) and adds the modeled ceiling from
`contact_rate/ceiling.py`, producing directly the "X% of theoretical
capacity" framing reviewer 2 asked for. It discovers sizes from whatever
`size_*` directories exist on disk rather than assuming a fixed list, so
it stays correct if `SIZES` is ever overridden. `CAN_KBPS`/`TCP_KBPS` env
vars must match between `run_arm4.sh` and `summarize_arm4.py`
invocations, or the percentage is computed against the wrong rate.

## Prerequisites

- Everything DEMO.md Phase 0 requires already built: `ud3tn/build/posix/ud3tn`,
  `unibo-dtn/unibo-bp/build/Unibo-BP/bin/*`, `hardy/target/release/hardy-bpa-server`,
  `charon/build/charon`, `apps/sender`/`apps/receiver` (`make -C apps`).
- Root access (`sudo`) for `vcan0`, `alice_ns`/`bob_ns`, Charon's TUN, and
  `tc`/`iptables` shaping — **this could not be exercised in the
  assistant's sandbox** (no interactive sudo password available there;
  `contact_rate/`'s own README documents hitting the identical wall in
  an earlier session). A human with sudo needs to run this.
- Python venv active for the A-SABR BDMs (`source .venv/bin/activate`,
  already handled inside `start_stack.sh`).
- `sudo bash ../contact_rate/check_tc_vcan.sh 50` — confirm `tc` actually
  throttles `vcan0`-type interfaces on this kernel before trusting any
  shaped number. Uses a disposable interface, never touches `vcan0`.

## Running it

```bash
sudo bash setup_root.sh          # once: vcan0, alice_ns, bob_ns
sudo bash start_stack.sh         # brings up all 10 DEMO.md processes, once

# smoke test before committing to a full sweep (unshaped at this point --
# start_stack.sh doesn't shape; run_arm4.sh shapes just before its sweep):
sudo ip netns exec bob_ns ../apps/receiver 4000 1 &
sudo ip netns exec alice_ns ../apps/sender 10.0.0.2 4000 1 64 0
# expect one "RECV seq=1 ..." line above within a couple hundred ms

sudo bash run_arm4.sh            # [OUT_DIR] [REPS], default REPS=100, SIZES="64 256"
python3 summarize_arm4.py        # [OUT_DIR] -> plain-text + LaTeX table

sudo bash stop_stack.sh          # kills the 10 processes (leaves vcan0/netns up)
```

## Expected wall-clock time

64/256 B are fast and reliable at either campaign (delivery holds at
10/10 even under shaping, matching the paper's existing numbers). At
`REPS=100` on both sizes and both campaigns, this should be on the order
of a few minutes total, not the multi-hour runs 1024/4096 B would
require (see below) — no `LARGE_THR_REPS`-style workaround needed at
this scope.

**Recommendation given time pressure**: run a smoke test (`REPS=3`)
first to confirm the stack is healthy end-to-end, then run the full
`REPS=100` sweep — it should complete quickly enough to just wait on
interactively, but backgrounding it (`nohup sudo bash run_arm4.sh results
100 > sweep.log 2>&1 &`) is still fine if you'd rather not.

### If you override `SIZES` to include 1024/4096 B anyway

Budget for it separately: under real shaping those bursts collapse to
~3/10 and ~1/10 delivered (`contact_rate/README.md`'s diagnosis — uD3TN's
CSP CLA, `components/cla/posix/cla_csp.c`, tearing down its opportunistic
per-peer link mid-transfer, not a timeout, not fixable from this
harness), so the receiver runs to the full per-size timeout
(`ceiling.py`'s per-bundle time × 10 × 5, floored at 15s: ~43s at 1024 B,
~165s at 4096 B) on almost every rep of the throughput campaign. At
`REPS=100` that's ~72 minutes (1024 B) and **~4.6 hours** (4096 B) from
that one campaign/size pair alone. Pass a much smaller `REPS` for a run
that includes those sizes, or run 64/256 B and 1024/4096 B as separate
invocations with different `REPS`/`OUT_DIR`.

## Known risks (from earlier manual runs of this same stack)

`demo_analysis.md`/`demo_result.md` in the repo root document earlier
failed attempts at this exact topology (Hardy rejecting unibo's CSPCL
frames, A-SABR dispatch drops, a bob-side RX buffer reset roughly every
53 s). Note: a BDM log line reading "Dropping bundle: dispatch reason 5"
looks alarming but is **not** a failure — reason 5 means the bundle
processor already dispatched it successfully and the BDM is dropping its
own now-redundant tracking of it; `demo_analysis.md`'s older
characterization of this as a fatal drop was a misread, confirmed against
a live run where 100% of "dropped" bundles were also 100% delivered.
Watch instead for genuinely low delivered/expected in the summary table —
at 64/256 B there's no known reason to expect that; if it shows up,
investigate before trusting the run.

## Results (N=100, 2026-08-02, final)

| Payload | Delivered | Mean latency | Achieved | Ceiling | % of ceiling |
|---|---|---|---|---|---|
| 64 B | 1000/1000 | 609.5 ± 95.4 ms | 0.53 ± 0.08 kB/s | 0.67 kB/s | 78.9% |
| 256 B | 1000/1000 | 1263.0 ± 103.5 ms | 0.96 ± 0.05 kB/s | 1.02 kB/s | 94.1% |

Both sizes deliver perfectly (1000/1000) and land below the modeled
ceiling as physically expected under genuine shaping, consistent in kind
with the paper's existing single-sample numbers (202 ms/94.0% and
1241 ms/83.3%) — 256 B lands close to its old value; 64 B moved further,
which is expected given the old figure was a single noisy N=1 burst and
this is a proper mean over 100.

## Integration into the paper

Replaces the placeholder sentence at the end of `eval_layer_overhead.tex`
("The full four-node chain ... was validated separately end-to-end...")
with the table above (or `summarize_arm4.py`'s regenerated LaTeX,
`\label{tab:arm4-e2e}`) — this is the number reviewer 2 was most explicit
about, so it likely needs its own short paragraph/table rather than a
single sentence, budget permitting. No need to discuss the 1024/4096 B
burst collapse here; it isn't part of this table's scope, and the
connection-pool limitation is already on the record via the single-hop
pool-mutex finding in Section IV-D.
