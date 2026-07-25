# bundle_overhead — Section 3 benchmark: raw CSP vs CSP/BP(CSPCL)

Implements the benchmark described in `paper_comments.md` Section 3: quantifying
the cost of layering the Bundle Protocol over CSP via CSPCL, as a function of
**bundle granularity** — the number of CSP-packet-equivalent units batched into
a single bundle — rather than as a function of raw payload byte size.

## Design

Both arms bring up an **identically-tuned CSP/CAN stack** (same buffer sizes,
same CAN interface config, same connection-table capacity), but from
completely separate code paths, so the comparison isn't just "these calls
aren't exercised" — the two binaries are structurally incapable of touching
each other's code:

- **Arm A — raw CSP** (`csp_raw_sender` / `csp_raw_receiver`): brings up the
  stack via `bare_csp_stack.c`, which duplicates only the plain-libcsp part of
  `cspcl_init()` (csp_init + CAN interface + route + router task) with **zero
  reference to `cspcl.h`**. These two binaries link only `libcsp`, never
  `libcspcl` — confirmed with `nm csp_raw_sender | grep cspcl` (no matches).
  They open one persistent CSP RDP connection and call `csp_send()` /
  `csp_read()` directly, one unit per CSP packet. Models how a legacy CSP
  application talks CSP-to-CSP today, with no BP/CSPCL in the path at all.
- **Arm B — CSP/BP via CSPCL** (`bundle_sender` / `bundle_receiver`): brings
  up the stack via the real `cspcl_init()` (`csp_stack.c`), then batches **N**
  units into one buffer and hands it to the real `cspcl_send_bundle()` /
  `cspcl_recv_bundle()` — the exact functions a BPA calls to move a BP7
  bundle over CSPCL (SFP fragmentation + RDP connection-pool lookup/
  eviction/invalidation). N is swept (default 1, 2, 4, 8, 16, 32, 64).

An earlier version of Arm A called `cspcl_init()` too (purely for stack-setup
parity), which left CSPCL's connection pool and an idle RX socket initialized
in the same process even though the benchmarked path never touched them —
technically inert, but not a clean claim for a paper ("CSPCL is up but
unused" vs "CSPCL is not linked at all"). `bare_csp_stack.c` removes that
ambiguity entirely.

Reusing the real `cspcl.c`/`cspcl.h` library (not a synthetic stand-in) means
the measured "compute time" overhead — wall-clock time around each
`cspcl_send_bundle()` call — is genuine library behavior, including its
connection churn (CSPCL always invalidates the pooled connection after a send
today, so every bundle currently pays a fresh RDP handshake; that cost shows
up naturally in the numbers rather than being hidden or equalized away).

Two known simplifications, both called out so they don't get mistaken for
measured data:

1. **No full BP7 encoding.** This benchmark calls `cspcl_send_bundle()`
   directly, bypassing a full BPA, so no real BP7 primary block is put on the
   wire. `overhead_table.py`'s `bp7_bundle_overhead_bytes()` is not a guessed
   constant — it derives the exact CBOR byte count of a minimal BP7 bundle
   field-by-field from RFC 9171 (indefinite-length array framing in §4.1,
   8-field primary block in §4.3.1, ipn/dtn:none EID encoding in §4.2.5,
   5-field payload block in §4.3.2, CBOR unsigned-integer/array/byte-string
   length-prefix sizing from RFC 8949 §3.1), using this benchmark's actual
   addressing (`ipn` node numbers 20/21, service 10 = `CSPCL_PORT_BP`,
   `dtn:none` report-to since no status reports are requested, CRC type 0).
   It comes out to 55B total framing (42-43B primary+payload-header
   overhead + 12-13B for the indefinite-array start/break bytes — see the
   script's module docstring for the field-by-field breakdown), essentially
   flat across the N sweep since only the payload-length CBOR prefix and
   the creation-timestamp value are bundle-dependent. Still worth
   cross-checking against a measured value from an actual
   Hardy/Unibo-BP/uD3TN bundle if a full BPA encoding is ever wired in, in
   case those implementations add extension blocks (e.g. previous-node,
   hop-count, bundle-age) this derivation doesn't assume.
2. **Arm A always uses N=1.** Raw CSP has no bundling concept; N only
   parameterizes Arm B.

## Two test shapes per the manager's notes

- **Single-bundle test** (fixed count, burst): isolates per-bundle
  latency and the real `cspcl_send_bundle()` compute time at each N.
  Expected shape: overhead is large at N=1 (full per-bundle cost paid for a
  single unit's worth of payload) and shrinks as N grows and that fixed cost
  is amortized ("bundle petit = overhead important").
- **Streaming test** (fixed duration, continuous): sustained throughput
  (bundles/sec, units/sec-equivalent, kB/s) for CSP-only vs CSP/BP at each N,
  to see whether the overhead behaves differently under continuous load than
  in a one-shot exchange.

## Build

Requires libcsp and cspcl already built (see repo `README.md` Step 4 —
`libcsp/build/libcsp.a` and `cspcl/build/libcspcl.a` must exist).

```bash
make
```

## Run

Needs a SocketCAN interface both nodes can reach. Default is a dedicated
`vcanbench0` so this runs standalone without the full DEMO.md stack:

```bash
sudo modprobe vcan
sudo ip link add dev vcanbench0 type vcan
sudo ip link set up vcanbench0
```

(Set `CAN_IFACE=vcan0` to instead co-locate the benchmark on the demo bus —
bench CSP addresses default to 20/21 to avoid colliding with the demo's
1/2/3. CSP v1.6 addresses are 5 bits wide — 0-31, with 31 reserved for
broadcast — so stay under that ceiling if you override `TX_ADDR`/`RX_ADDR`.)

```bash
./run_bundle_overhead.sh [output_dir]
```

This does not itself need root (unlike `apps/measure.sh`/`apps/disrupt.sh`,
which need root for `ip netns exec`) — only creating the vcan interface does,
once, ahead of time.

Tunable via environment variables (see top of `run_bundle_overhead.sh`):
`CAN_IFACE`, `TX_ADDR`, `RX_ADDR`, `UNIT_SIZE`, `N_SWEEP`, `BUNDLE_COUNT`,
`STREAM_DURATION_S`, `RAW_COUNT`, `RAW_STREAM_DURATION_S`.

## Verification

Two sanity checks worth re-running if the benchmark is ever modified:

1. **No CSPCL in Arm A**: `nm csp_raw_sender csp_raw_receiver | grep -i cspcl`
   should print nothing, and `ldd` should show no `libcspcl` dependency.
2. **Traffic really crosses the CAN device** (not a same-host shortcut):
   run `candump <can_iface>` in a spare terminal while the benchmark runs.
   CAN, unlike IP, has no kernel routing-table shortcut to worry about even
   when both processes are on the same host — SocketCAN sockets bound to a
   device are inherently broadcast — but `candump` gives direct proof rather
   than an argument from first principles.

## Output

Per-N summary table (bundles/sec, units/sec-equivalent, kB/s, mean latency,
delivery rate, mean measured `cspcl_send_bundle()` time), raw per-run logs in
`output_dir/`, and the analytic memory-overhead table from
`overhead_table.py`. Compare the Arm B rows against the `arm_a_*.log`
baselines to get the overhead delta the paper needs at each N.
