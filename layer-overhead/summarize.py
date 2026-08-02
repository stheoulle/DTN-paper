#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
"""
summarize.py — builds the 3-row (CAN/CSP, CAN/CSP/BP, CAN/CSP/BP/CSP via
Charon) x N-size comparison table from run_all.sh's output, in both plain
text and LaTeX (matching main.tex's existing table style).

Statistics are computed ACROSS repetitions, not across packets within one
burst: packets within a burst are not independent samples (packet k's
latency depends mechanically on packet k-1's full send-ack-reconnect cycle
via the pool-wide mutex — see main.tex's "Connection-Pool and Link Behavior
Under Load"). Each repetition (one full COUNT-packet burst) is treated as
one independent trial; mean/stddev of delivery rate, mean latency, and
throughput are computed over the REPS repetitions.

Layout expected (written by run_arm1/2/3.sh):
    results/arm1/rep_01.log, rep_01.timing, rep_02.log, ...
    results/arm2/size_64/rep_01.log, rep_01.timing, ...
    results/arm3/size_64/rep_01.log, rep_01.timing, ...

Usage: summarize.py [results_dir] [expected_count]
       expected_count must match the --count you passed to run_all.sh /
       run_arm*.sh (default: 10) — used to compute delivery rate.
"""
import re
import statistics
import sys
from pathlib import Path

ARMS = [
    ("arm1", "CAN/CSP"),
    ("arm2", "CAN/CSP/BP"),
    ("arm3", "CAN/CSP/BP/CSP (charon)"),
]
SIZES = [64, 256, 1024, 4096]
ARM1_UNIT_SIZE = 64  # must match run_arm1.sh's UNIT_SIZE

RECV_RE = re.compile(r"RECV seq=\d+ latency=([\d.]+)ms size=(\d+)")


class RepResult:
    """One repetition's outcome: a single independent trial."""

    def __init__(self, delivered, expected, mean_latency_ms, bytes_per_s):
        self.delivered = delivered
        self.expected = expected
        self.mean_latency_ms = mean_latency_ms  # mean across packets *within* this rep
        self.bytes_per_s = bytes_per_s


def parse_one_rep(log: Path, timing: Path, size: int, expected_count: int):
    if not log.exists():
        return None

    latencies = []
    for line in log.read_text().splitlines():
        m = RECV_RE.search(line)
        if m:
            latencies.append(float(m.group(1)))

    delivered = len(latencies)
    mean_latency_ms = sum(latencies) / delivered if delivered else None

    bytes_per_s = None
    if timing.exists() and delivered:
        t_start_ns, t_end_ns = map(int, timing.read_text().split())
        elapsed_s = (t_end_ns - t_start_ns) / 1e9
        if elapsed_s > 0:
            bytes_per_s = (delivered * size) / elapsed_s

    return RepResult(delivered, expected_count, mean_latency_ms, bytes_per_s)


def collect_reps(results_dir: Path, arm: str, size: int, expected_count: int):
    """Returns a list of RepResult, one per repetition found on disk."""
    if arm == "arm1":
        rep_dir = results_dir / arm
        pattern = "rep_*.log"
        eff_size = ARM1_UNIT_SIZE
    else:
        rep_dir = results_dir / arm / f"size_{size}"
        pattern = "rep_*.log"
        eff_size = size

    if not rep_dir.exists():
        return []

    reps = []
    for log in sorted(rep_dir.glob(pattern)):
        timing = log.with_suffix(".timing")
        r = parse_one_rep(log, timing, eff_size, expected_count)
        if r is not None:
            reps.append(r)
    return reps


def mean_stdev(values):
    values = [v for v in values if v is not None]
    if not values:
        return None, None
    if len(values) == 1:
        return values[0], 0.0
    return statistics.mean(values), statistics.stdev(values)


def summarize_reps(reps):
    if not reps:
        return None

    total_delivered = sum(r.delivered for r in reps)
    total_expected = sum(r.expected for r in reps)
    per_rep_rate = [r.delivered / r.expected for r in reps if r.expected]
    rate_mean, rate_std = mean_stdev(per_rep_rate)
    lat_mean, lat_std = mean_stdev([r.mean_latency_ms for r in reps])
    bps_mean, bps_std = mean_stdev([r.bytes_per_s for r in reps])

    return {
        "n_reps": len(reps),
        "total_delivered": total_delivered,
        "total_expected": total_expected,
        "rate_mean": rate_mean,
        "rate_std": rate_std,
        "lat_mean": lat_mean,
        "lat_std": lat_std,
        "bps_mean": bps_mean,
        "bps_std": bps_std,
    }


def fmt_throughput_cell(s):
    if s is None or s["bps_mean"] is None:
        return "N/A"
    cell = f"{s['bps_mean'] / 1000:.1f} +/- {s['bps_std'] / 1000:.1f} kB/s"
    if s["total_delivered"] < s["total_expected"]:
        cell += f" ({s['total_delivered']}/{s['total_expected']})"
    return cell


def fmt_throughput_cell_tex(s):
    if s is None or s["bps_mean"] is None:
        return "N/A"
    cell = f"{s['bps_mean'] / 1000:.1f} $\\pm$ {s['bps_std'] / 1000:.1f}"
    if s["total_delivered"] < s["total_expected"]:
        cell += f" ({s['total_delivered']}/{s['total_expected']})"
    return cell


def fmt_latency_cell(s):
    if s is None or s["lat_mean"] is None:
        return "N/A"
    return f"{s['lat_mean']:.2f} +/- {s['lat_std']:.2f} ms"


def main():
    results_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "results"
    expected_count = int(sys.argv[2]) if len(sys.argv) > 2 else 10

    table = {}  # arm -> size -> summary dict
    for arm, _ in ARMS:
        table[arm] = {}
        for size in SIZES:
            reps = collect_reps(results_dir, arm, size, expected_count)
            table[arm][size] = summarize_reps(reps)

    # Arm 1 has no bundling concept: collapse to one shared value.
    arm1_values = [s for s in table["arm1"].values() if s]
    arm1_shared = arm1_values[0] if arm1_values else None
    n_reps_arm1 = arm1_shared["n_reps"] if arm1_shared else 0

    all_n_reps = [n_reps_arm1] + [
        table[arm][s]["n_reps"]
        for arm, _ in ARMS if arm != "arm1"
        for s in SIZES if table[arm][s]
    ]
    n_reps_found = max(all_n_reps) if all_n_reps else 0

    col_w = 32
    print(f"Layer overhead — mean +/- stddev across repetitions, {expected_count} packets/bundles per rep\n")

    header = "Layer".ljust(24) + "".join(f"{s}B".rjust(col_w) for s in SIZES)
    print("Throughput (kB/s):")
    print(header)
    print("-" * len(header))
    for arm, label in ARMS:
        if arm == "arm1":
            cell = fmt_throughput_cell(arm1_shared)
            row = label.ljust(24) + "".join(cell.rjust(col_w) for _ in SIZES)
        else:
            row = label.ljust(24) + "".join(
                fmt_throughput_cell(table[arm][s]).rjust(col_w) for s in SIZES
            )
        print(row)

    print("\nMean latency per repetition (ms):")
    print(header)
    print("-" * len(header))
    for arm, label in ARMS:
        if arm == "arm1":
            cell = fmt_latency_cell(arm1_shared)
            row = label.ljust(24) + "".join(cell.rjust(col_w) for _ in SIZES)
        else:
            row = label.ljust(24) + "".join(
                fmt_latency_cell(table[arm][s]).rjust(col_w) for s in SIZES
            )
        print(row)

    print(f"\nRepetitions found per arm/size (max found: {n_reps_found}):")
    for arm, label in ARMS:
        if arm == "arm1":
            print(f"  {label}: {n_reps_arm1} reps (shared across all sizes)")
        else:
            counts = [table[arm][s]["n_reps"] if table[arm][s] else 0 for s in SIZES]
            print(f"  {label}: " + ", ".join(f"{s}B={c}" for s, c in zip(SIZES, counts)))

    # LaTeX table, matching main.tex's existing style (see tab:throughput).
    print("\n--- LaTeX (paste into main.tex once the paper tables are revisited) ---\n")
    print(r"\begin{table}[htbp]")
    print(
        r"\caption{Achieved throughput by protocol layer. Each cell is the "
        f"mean $\\pm$ stddev across {n_reps_found} independent repetitions "
        f"of a {expected_count}-packet burst; (delivered/expected) is shown "
        r"only when a cell's aggregate delivery fell below 100\%.}"
    )
    print(r"\label{tab:layer-overhead}")
    print(r"\centering")
    print(r"\begin{tabular}{l" + "c" * len(SIZES) + "}")
    print(r"\hline")
    print("Layer & " + " & ".join(f"{s}~B" for s in SIZES) + r" \\")
    print(r"\hline")
    for arm, label in ARMS:
        if arm == "arm1":
            cell = fmt_throughput_cell_tex(arm1_shared)
            cells = [cell] * len(SIZES)
        else:
            cells = [fmt_throughput_cell_tex(table[arm][s]) for s in SIZES]
        print(f"{label} & " + " & ".join(cells) + r" \\")
    print(r"\hline")
    print(r"\end{tabular}")
    print(r"\end{table}")


if __name__ == "__main__":
    main()
