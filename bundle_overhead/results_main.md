# Section 3 benchmark results — `main` branch (throughput analysis)

Raw data: `bundle_overhead/results_main/`. This is a numbers-only read of
what's in those logs — no code changes, no root-causing, just what the
throughput figures say on `main`.

## Arm A — raw CSP over CAN (no CSPCL/BP)

| test | delivered | latency mean (ms) | throughput |
| --- | --- | --- | --- |
| burst (200 pkts, 36B) | 200/200 (100%) | 0.085 | 25607.3 pkt/s |
| stream (36B) | 503184 sent | 0.038 | 40000.6 pkt/s |

Baseline is healthy and fast, as expected — no CSPCL involved.

## Arm B — CSP/BP via CSPCL, burst test (target: 30 bundles per N)

| N | bundle_len (B) | delivered | bundles/sec | units/sec-equiv | mean `cspcl_send_bundle()` (ms) |
| --- | --- | --- | --- | --- | --- |
| 1  | 36   | 30/30 (100%) | 3.44 | 3.4   | 300.9 |
| 2  | 72   | 30/30 (100%) | 3.44 | 6.9   | 300.9 |
| 4  | 144  | 30/30 (100%) | 3.44 | 13.8  | 301.0 |
| 8  | 288  | 30/30 (100%) | 3.43 | 27.4  | 301.1 |
| 16 | 576  | 27/30 (90%)  | 5.35 | 85.6  | 0.355 |
| 32 | 1152 | 30/30 (100%) | 3.42 | 109.4 | 302.1 |
| 64 | 2304 | 30/30 (100%) | 3.41 | 218.2 | 303.4 |

## Arm B — CSP/BP via CSPCL, streaming test (~10s duration)

| N | bundle_len (B) | delivered | bundles/sec | units/sec-equiv | mean `cspcl_send_bundle()` (ms) |
| --- | --- | --- | --- | --- | --- |
| 1  | 36   | 34 sent | 2.62  | 2.6   | 301.1 |
| 2  | 72   | 34 sent | 2.63  | 5.3   | 300.9 |
| 4  | 144  | 34 sent | 2.62  | 10.5  | 301.2 |
| 8  | 288  | 34 sent | 2.62  | 21.0  | 301.1 |
| 16 | 576  | 48 recv | 46.99 | 751.8 | —     |
| 32 | 1152 | 34 sent | 2.62  | 83.8  | 302.2 |
| 64 | 2304 | 33 sent | 2.59  | 165.8 | 303.2 |

## Throughput vs. raw CSP (Arm A)

Using `units/sec-equivalent` (`bundles/sec * N`) against Arm A's
pkt/s as a like-for-like unit:

| N | burst: Arm A / Arm B ratio | stream: Arm A / Arm B ratio |
| --- | --- | --- |
| 1  | 7444x  | 15267x |
| 2  | 3722x  | 7605x  |
| 4  | 1861x  | 3817x  |
| 8  | 933x   | 1908x  |
| 16 | 299x   | 53x    |
| 32 | 234x   | 477x   |
| 64 | 117x   | 241x   |

## Key numbers

- **Every `mean cspcl_send_bundle()` value is ~300-303ms, flat across N**,
  except N=16 which is the one outlier in both the burst and streaming
  tables (0.355ms burst / no comparable figure in streaming, and
  correspondingly far higher bundles/sec: 5.35 burst, 46.99 streaming).
  All other N values, in both burst and streaming, land within ~1ms of
  each other regardless of bundle size (36B up to 2304B) — the ~300ms cost
  does not scale with N or bundle size at all.
- **Bundles/sec is correspondingly flat** at ~3.4/sec (burst) and ~2.6/sec
  (streaming) for every N except 16. `units/sec-equivalent` still climbs
  with N only because each bundle carries more payload, not because more
  bundles/sec are being sent.
- **Streaming duration doesn't help**: with a ~300ms cost per bundle, only
  ~33-34 bundles fit in a ~10s window (10000ms / 300ms ≈ 33), which matches
  the streaming `delivered` column almost exactly for every N except 16.
- **N=16 is the anomaly in both tables** — noticeably faster (sub-ms send
  time, 90% delivery in burst; ~47 bundles/sec in streaming) than every
  other N, which are all uniform at the ~300ms/~3 bundles-per-second level.
- Arm B's throughput deficit vs. Arm A ranges from **117x (N=64 streaming)
  up to 15267x (N=1 streaming)** — the gap narrows as N grows simply
  because more payload rides along with the same flat ~300ms-per-bundle
  cost, not because the per-bundle cost itself improves.
