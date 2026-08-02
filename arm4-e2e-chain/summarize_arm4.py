#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
"""
summarize_arm4.py -- builds the R2-requested table for the full 4-node
chain: delivered/N, mean latency, achieved throughput, modeled ceiling
(contact_rate/ceiling.py, same 50/100 kbps model as demo/alice.cp), and
% of ceiling -- mean +/- stddev across REPS independent repetitions, not
across packets within one burst (see layer-overhead/summarize.py for why:
packet k's latency depends mechanically on packet k-1's send-ack cycle
via CSPCL's pool-wide mutex, so within-burst packets are not independent
trials; each rep is).

Assumes run_arm4.sh actually shaped the links to CAN_KBPS/TCP_KBPS via
contact_rate/shape_links.sh before collecting these results -- on an
unshaped vcan0/loopback link, achieved throughput is bound only by
software overhead and regularly exceeds the modeled ceiling (900%+ of it
at 1024/4096 B, observed when this was first tried without shaping),
which answers a different question than reviewer 2 asked. CAN_KBPS/
TCP_KBPS below must match whatever run_arm4.sh was actually invoked
with (env overrides), or the "% of ceiling" column is comparing against
the wrong rate.

This is the direct answer to reviewer 2's explicit ask (paper_comments.md
/ the review): "bundle delivery latency (4-hop), throughput vs modeled
50/100 kbps rates" -- layer-overhead's Table I is a deliberately
different, single-hop, unshaped-link measurement (see its own README's
opening paragraph) and was never meant to substitute for this one.

Usage: summarize_arm4.py [results_dir] [expected_count_throughput] [expected_count_latency]
Env overrides: CAN_KBPS=50 TCP_KBPS=100 (must match run_arm4.sh's invocation)
"""
import os
import re
import statistics
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR.parent / "contact_rate"))
import ceiling  # noqa: E402

CAN_KBPS = float(os.environ.get("CAN_KBPS", 50.0))
TCP_KBPS = float(os.environ.get("TCP_KBPS", 100.0))


def discover_sizes(results_dir: Path):
    """Sizes actually present on disk, not a hardcoded list -- run_arm4.sh's
    SIZES default is 64/256 B only (realistic CSP telemetry/command sizes;
    see its header comment for why 1024/4096 B are deliberately excluded),
    but this stays correct if that's ever overridden. Only throughput_results
    is authoritative now (see main()'s comment on why mean latency is
    derived from it too, not a separate isolated-packet campaign)."""
    sizes = set()
    for d in (results_dir / "throughput_results").glob("size_*"):
        try:
            sizes.add(int(d.name.removeprefix("size_")))
        except ValueError:
            continue
    return sorted(sizes)

RECV_RE = re.compile(r"RECV seq=\d+ latency=([\d.]+)ms size=(\d+)")


def parse_one_rep(log: Path, timing: Path, size: int):
    if not log.exists():
        return None
    latencies = [float(m.group(1)) for m in RECV_RE.finditer(log.read_text())]
    delivered = len(latencies)
    if delivered == 0:
        return None
    mean_latency_ms = sum(latencies) / delivered
    bytes_per_s = None
    if timing.exists():
        t0, t1 = map(int, timing.read_text().split())
        elapsed_s = (t1 - t0) / 1e9
        if elapsed_s > 0:
            bytes_per_s = delivered * size / elapsed_s
    return delivered, mean_latency_ms, bytes_per_s


def collect_reps(results_dir: Path, campaign: str, size: int):
    size_dir = results_dir / campaign / f"size_{size}"
    if not size_dir.exists():
        return []
    reps = []
    for log in sorted(size_dir.glob("rep_*.log")):
        timing = log.with_suffix(".timing")
        r = parse_one_rep(log, timing, size)
        if r is not None:
            reps.append(r)
    return reps


def mean_std(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None, None
    if len(vals) == 1:
        return vals[0], 0.0
    return statistics.mean(vals), statistics.stdev(vals)


def main():
    results_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else SCRIPT_DIR / "results"
    expected_thr = int(sys.argv[2]) if len(sys.argv) > 2 else 10

    print(f"Arm 4 -- full 4-node chain vs. modeled {CAN_KBPS:.0f}/{TCP_KBPS:.0f} kbps "
          f"contact rate\n")

    sizes = discover_sizes(results_dir)
    if not sizes:
        print(f"warning: no size_* directories found under {results_dir}", file=sys.stderr)

    rows = []
    for size in sizes:
        thr_reps = collect_reps(results_dir, "throughput_results", size)

        thr_delivered = sum(r[0] for r in thr_reps)
        thr_expected = len(thr_reps) * expected_thr
        bps_mean, bps_std = mean_std([r[2] for r in thr_reps])

        # Mean latency is derived from the throughput campaign's own
        # per-rep within-burst mean (r[1]), NOT a separate isolated
        # single-packet campaign. A single packet sent after the idle gap
        # between reps always finds shape_links.sh's tbf token bucket
        # freshly refilled (burst=64, deliberately tiny, refills in ~10ms
        # at 50kbit/s) and gets the same free ride as any burst's first
        # packet -- confirmed against real data: an isolated-packet rep
        # measured 9.4ms, matching a same-size burst's *first* packet
        # (8.0ms) almost exactly, while that same burst's later packets
        # (once the token bucket was drained) cost ~101ms each, the real
        # shaped rate. An isolated-send campaign against a small-burst
        # tbf shaper measures the burst-allowance artifact, not shaped
        # latency, and cannot be fixed by more reps. Burst-mean latency
        # is what the paper's existing, already-reviewed Table D used too
        # (apps/measure.sh, COUNT=10 burst) -- same convention, just
        # averaged across REPS independent bursts here instead of one.
        lat_mean, lat_std = mean_std([r[1] for r in thr_reps])

        ceil = ceiling.end_to_end_ceiling(size, CAN_KBPS, TCP_KBPS)
        ceil_kBps = ceil["throughput_kBps"]
        pct_ceiling = (bps_mean / 1000 / ceil_kBps * 100) if bps_mean else None

        rows.append({
            "size": size,
            "n_thr_reps": len(thr_reps), "thr_delivered": thr_delivered, "thr_expected": thr_expected,
            "lat_mean": lat_mean, "lat_std": lat_std,
            "bps_mean": bps_mean, "bps_std": bps_std,
            "ceil_kBps": ceil_kBps, "pct_ceiling": pct_ceiling,
        })

    col_w = 16
    header = ("Payload".ljust(10) + "Delivered".rjust(col_w)
               + "Mean lat(ms)".rjust(col_w) + "Achieved(kB/s)".rjust(col_w)
               + "Ceiling(kB/s)".rjust(col_w) + "% ceiling".rjust(col_w))
    print(header)
    print("-" * len(header))
    for r in rows:
        lat_str = f"{r['lat_mean']:.1f}+/-{r['lat_std']:.1f}" if r["lat_mean"] is not None else "N/A"
        bps_str = f"{r['bps_mean']/1000:.2f}+/-{r['bps_std']/1000:.2f}" if r["bps_mean"] is not None else "N/A"
        pct_str = f"{r['pct_ceiling']:.1f}%" if r["pct_ceiling"] is not None else "N/A"
        print(
            f"{str(r['size'])+'B':<10}"
            f"{str(r['thr_delivered'])+'/'+str(r['thr_expected']):>{col_w}}"
            f"{lat_str:>{col_w}}"
            f"{bps_str:>{col_w}}"
            f"{r['ceil_kBps']:>{col_w}.2f}"
            f"{pct_str:>{col_w}}"
        )

    print(f"\nReps found: " + ", ".join(
        f"{r['size']}B: {r['n_thr_reps']}" for r in rows))

    print("\n--- LaTeX (paste into main.tex; matches the original tab:throughput column layout) ---\n")
    print(r"\begin{table}[htbp]")
    n_reps_note = rows[0]["n_thr_reps"] if rows else 0
    print(
        r"\caption{Full 4-node chain (alice"
        r"$\to$unibo$\to$hardy$\to$bob, via Charon), CAN hops and the "
        r"alice$\leftrightarrow$unibo link shaped (\texttt{tc}) to enforce "
        f"the contact plan's modeled {CAN_KBPS:.0f}/{TCP_KBPS:.0f}~kbps rate. "
        f"Mean $\\pm$ stddev across {n_reps_note} independent repetitions per size.}}"
    )
    print(r"\label{tab:arm4-e2e}")
    print(r"\centering")
    print(r"\scriptsize")
    print(r"\begin{tabular}{lccccc}")
    print(r"\hline")
    print(r"Payload & Delivered & Mean lat.\ (ms) & Achieved (kB/s) & Ceiling (kB/s) & \% of ceiling \\")
    print(r"\hline")
    for r in rows:
        lat_str = f"{r['lat_mean']:.1f} $\\pm$ {r['lat_std']:.1f}" if r["lat_mean"] is not None else "N/A"
        bps_str = f"{r['bps_mean']/1000:.2f} $\\pm$ {r['bps_std']/1000:.2f}" if r["bps_mean"] is not None else "N/A"
        pct_str = f"{r['pct_ceiling']:.1f}\\%" if r["pct_ceiling"] is not None else "N/A"
        delivered_str = f"{r['thr_delivered']}/{r['thr_expected']}"
        print(f"{r['size']}~B & {delivered_str} & {lat_str} & {bps_str} & {r['ceil_kBps']:.2f} & {pct_str} \\\\")
    print(r"\hline")
    print(r"\end{tabular}")
    print(r"\end{table}")


if __name__ == "__main__":
    main()
