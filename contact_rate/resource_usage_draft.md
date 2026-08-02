# Draft content — Resource Usage (BLOCKED on real data, see note below)

## Insert as a new subsection in Section VI (Results), e.g. after
## "Store-and-Forward Recovery Under Node Disruption" (VI-C) as VI-D

### D. Resource Usage of the Relay/BPA Processes

**STATUS: script built and unit-validated; NOT yet run against the live
stack. Do not insert real numbers into paper.tex until this has actually
been executed once with root access — see "Why this is a placeholder"
below.**

<!-- TEMPLATE — fill in from contact_rate/results_resource_*/resource_usage_report.md
     after running: sudo ./contact_rate/measure_resource_usage.sh -->

We measured CPU and memory usage of the four persistent relay/BPA
daemons (alice's and bob's uD3TN, `unibo-bp-cspcl`, and
`hardy-bpa-server`) and the two `charon` instances fronting alice and bob,
sampled at [SAMPLE_INTERVAL_S]s intervals via `ps -o %cpu,rss` while the
same payload sizes and shaped-link conditions used in
Section~\ref{sec:results-throughput} (64/256/1024/4096~B, ten packets per
size, CAN hops at 50~kbit/s, alice$\leftrightarrow$unibo at 100~kbit/s)
were sent through the chain.

| Process | Payload | Mean %CPU | Peak %CPU | Peak RSS |
| --- | --- | --- | --- | --- |
| alice uD3TN | 64 B | TBD | TBD | TBD |
| bob uD3TN | 64 B | TBD | TBD | TBD |
| unibo-bp-cspcl | 64 B | TBD | TBD | TBD |
| hardy-bpa-server | 64 B | TBD | TBD | TBD |
| charon (alice_ns) | 64 B | TBD | TBD | TBD |
| charon (bob_ns) | 64 B | TBD | TBD | TBD |
| ... | 256/1024/4096 B | ... | ... | ... |

[1-2 paragraphs once real numbers exist: which process dominates CPU
(prior informal observation across this session's demo runs is that
`hardy-bpa-server`, being the only Rust/async BPA of the three and
running full contact-graph routing, is worth checking against the two
uD3TN instances and unibo's lighter CSPCL daemon — but this is an
expectation to verify, not a measured claim), whether CPU/RSS scale with
payload size or fragment count, and whether any process's footprint is
notable for a resource-constrained CubeSat target (the paper's target
platform is a 12U linux-based board, per Section VII).]

---

## Why this is a placeholder, not real numbers

This task required root/sudo access to bring up the full demo stack
(`vcan0`, `alice_ns`/`bob_ns` network namespaces, `charon`'s TUN
interfaces, and `tc`/`iptables` link shaping — all of DEMO.md Phases 1-3
and every script in this folder require root, same as
`run_contact_rate_measure.sh` and `test_paced_delivery.sh`). The sandboxed
session this script was built in has **no sudo password and no
passwordless sudo rule** for any command (`sudo -n true`, `sudo -n -v`,
and `sudo -l -n` all failed with "a password is required"; no
`SUDO_ASKPASS` helper or cached ticket was available either) — confirmed,
not assumed, before writing this note. Fabricating plausible-looking
numbers here instead would be worse than leaving this blocked: the whole
point of this exercise is to give the reviewer *real* measured data.

**What's ready:**

- `contact_rate/measure_resource_usage.sh` — complete, follows this
  folder's conventions (root check, netns/binary preconditions, trap-based
  shaping cleanup, markdown report output, env-var overrides). Syntax-
  checked (`bash -n`) and confirmed to fail correctly and loudly at the
  root check, matching every other script in this suite.
- The two pieces of logic specific to this script were unit-tested in
  isolation against real (non-root) sample processes, standing in for the
  parts that can't be exercised without the live stack:
  - **PID-pattern resolution**: compiled throwaway binaries invoked with
    the same argv shapes as the real daemons (e.g. `-e dtn://alice.dtn/`
    vs. `-e dtn://bob.dtn/` for the two uD3TN instances,
    `charon-alice.conf` vs. `charon-bob.conf` for the two charon
    instances) confirmed each `pgrep -f` pattern in the script matches
    exactly one process, and that a naive pattern (bare `"ud3tn"`) would
    have matched both instances — validating why the more specific
    `-e dtn://<name>.dtn/` pattern is required, not just convenient.
  - **Sampling and summarization**: `sample_loop`/`summarize_log`
    (extracted and run standalone against a real CPU-bound dummy process)
    correctly logged `ps -o %cpu=,rss=` samples every interval and
    computed mean/peak %cpu and peak RSS from them; the empty-log
    (zero-samples) path was also exercised and returns `N/A` rather than
    dividing by zero.

**What's needed to close this out:** someone with sudo on the demo
machine runs `sudo ./contact_rate/measure_resource_usage.sh` once with
the full DEMO.md stack up (Phases 1-3, T1-T9), then this file's table and
prose get filled in from the resulting
`resource_usage_report.md` — at that point the same "do not edit
paper.tex directly, draft first" rule this session's convention already
established applies before insertion.
