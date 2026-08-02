# layer-overhead — per-layer throughput comparison (CAN/CSP vs CAN/CSP/BP vs CAN/CSP/BP/CSP via Charon)

Answers the methodology question raised in review: isolate what each
protocol layer costs, on a **single node pair, same physical/virtual CAN
link, same everything except which layers are active** — rather than mixing
that question with the full 4-node heterogeneous chain (which is a
different, already-answered question: does the whole stack work
end-to-end; see the paper's Evaluation section).

Unlike `bundle_overhead/` (which isolates raw CSP vs. CSPCL by calling
`cspcl_send_bundle()` directly, bypassing any BPA — see its own
`zAIE.md`), Arm 2 here drives bundles through a **real uD3TN BPA's actual
AAP2 → bundle-processor → CSPCL CLA path**, the same code path the full
demo uses.

## Design

Two uD3TN nodes, `node-a` (CSP addr 1) and `node-b` (CSP addr 2), directly
linked over a dedicated `vcanlayer0` bus with a static FIB entry each way
(no A-SABR — routing algorithm overhead is deliberately out of scope for a
per-layer overhead measurement). Three arms exercise this pair (plus, for
Arm 1 only, a separate pair of standalone processes with no BPA at all):

| Arm | Layers | What actually runs |
|---|---|---|
| 1 | CAN/CSP | `bundle_overhead`'s `csp_raw_sender`/`csp_raw_receiver` (reused as-is — no BP, no CSPCL, zero `cspcl` symbols linked) |
| 2 | CAN/CSP/BP | `arm2-csp-bp/bundle_bench_send.py` / `bundle_bench_recv.py` — AAP2 `send_adu`/`receive_adu` against `node-a`/`node-b`'s real BPA, no Charon |
| 3 | CAN/CSP/BP/CSP (charon) | `apps/sender`/`apps/receiver` (already built for the paper's main Evaluation section) through a Charon instance in front of each node, tunneling IP over the same single BP hop |

Arm 1 has no bundling concept (it's one CSP packet per unit, no batching),
so its row is size-independent — a single value shared across all size
columns, as expected.

All three arms' receivers print the identical wire format
(`RECV seq=<n> latency=<ms>ms size=<n>`, embedded send timestamp via
`CLOCK_MONOTONIC`, see `arm2-csp-bp/pkt_hdr.py`'s docstring), so
`summarize.py` parses all of them uniformly and produces both a plain-text
table and a ready-to-paste LaTeX table (matching `main.tex`'s existing
`tab:throughput` style).

`vcanlayer0` and `layer_a_ns`/`layer_b_ns` are fully separate from the main
demo's `vcan0`/`alice_ns`/`bob_ns` — this can run alongside a live
`DEMO.md` session without interference.

## One-time setup (root)

```bash
sudo bash setup_root.sh
```

Creates `vcanlayer0` and the `layer_a_ns`/`layer_b_ns` network namespaces
(idempotent).

## Run everything

```bash
sudo bash run_all.sh [results_dir] [count]   # default: results/, 10 packets/bundles per size
python3 summarize.py [results_dir]
```

Requires root throughout (Arm 3 needs TUN + netns; running the whole sweep
under one privilege level avoids re-prompting mid-run). Sizes swept: 64,
256, 1024, 4096 B — matching the paper's existing Evaluation tables.

## Run one arm at a time

```bash
bash run_arm1.sh          # no root needed once vcanlayer0 exists
bash start_nodes.sh       # no root needed
bash run_arm2.sh
sudo bash run_arm3.sh     # needs root: TUN + netns
bash stop_nodes.sh
```

## Interactive Arm 3 (manual testing)

`run_arm3.sh` starts its own Charon pair, runs the sweep, and tears Charon
down again on exit — fine for automated runs, but inconvenient for poking at
the stack by hand. `up_arm3.sh` brings up the same stack (`setup_root.sh` +
`start_nodes.sh` + Charon alice/bob) and leaves it running detached, mirroring
`DEMO.md`'s phased "start the stack, then send traffic" structure:

```bash
sudo bash up_arm3.sh
# then, in another terminal, same shape as DEMO.md Phase 4:
sudo ip netns exec layer_b_ns apps/receiver 4000
sudo ip netns exec layer_a_ns apps/sender 10.1.0.2 4000
```

Tear down with `teardown.sh` (as above) before running `run_arm3.sh`'s
automated sweep — it starts its own Charon pair on the same TUN devices and
sockets, which conflicts with a stack left up by `up_arm3.sh`.

## Cleanup

```bash
bash teardown.sh          # stop processes only
sudo bash teardown.sh     # also remove vcanlayer0 and the netns
```

## Known simplifications

- Arm 2's FIB entries are static (`aap2-configure-link`), not A-SABR —
  intentional, to keep routing-algorithm overhead out of a per-layer
  comparison.
- Arm 1's benchmark sizes (64/256/1024/4096 B here) are larger than
  `bundle_overhead`'s own N-sweep (36–2304 B); `csp_raw_sender` takes
  `unit_size` directly so this needed no code changes, just different
  invocation arguments.
- Throughput is computed the same way `apps/measure.sh` computes it for the
  paper's main throughput table: wall-clock span from send-start to
  receiver-exit, captured by each `run_arm*.sh` script around the
  send/receive cycle (`size_<N>.timing` sidecar files) — not derived from
  the embedded per-packet latencies.
