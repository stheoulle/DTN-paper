# Draft content for Part B, items 1, 2, and 3 (qualitative)

## Insert as new Section VI, before "Future Work" (renumber that to VII)

### VI. RESULTS

We evaluated three properties of the stack: achieved throughput against
the contact plan's modeled 50/100 kbps rates, the connection-pool/link
mechanism's behavior when bundles are not evenly spaced, and store-and-forward
recovery when a node is disrupted mid-transfer.

#### A. Achieved Throughput vs. Modeled Contact Rate

We measured end-to-end delivery of application traffic tunneled through
Charon across the full four-node, three-BPA chain, for payload sizes
representative of typical CSP telemetry/command traffic. Ten packets were
sent per size, and achieved throughput was compared against a theoretical
ceiling derived bit-for-bit from RFC 9171 CBOR framing overhead, CSPCL/SFP
fragmentation, the CSP header, and — for the CAN hops — libcsp's CAN
Fragmentation Protocol and raw CAN 2.0B frame overhead.

| Payload | Delivered | Mean latency | Achieved | Ceiling | % of ceiling |
|---|---|---|---|---|---|
| 64 B  | 10/10 | 202 ms  | 0.63 kB/s | 0.67 kB/s | 94.0% |
| 256 B | 10/10 | 1241 ms | 0.85 kB/s | 1.02 kB/s | 83.3% |

At these sizes, CSPCL sustains 83–94% of the modeled contact rate
end-to-end, across three BPA implementations and two convergence-layer
hops, with no delivery loss. Notably, 256 B already exceeds a single SFP
fragment (243 B) and is sent as two fragments per bundle, yet remains fully
reliable.

#### B. Connection-Pool and Link Behavior Under Load

To exercise the connection pool described in Section III-A under load, we
repeated the measurement with larger payloads (1024 B and 4096 B), which
exceed a single SFP fragment (243 B after CSP/RDP/SFP header overhead) and
require 5 and 18 fragments respectively. Two transmission patterns were
compared: *burst* (all ten packets sent back-to-back with no inter-packet
delay) and *paced* (packets spaced to allow the previous bundle's transit,
derived from the same ceiling model used above).

| Payload | Burst delivery | Paced delivery | Paced achieved | Ceiling | % of ceiling |
|---|---|---|---|---|---|
| 1024 B | 3/10 | 10/10 | 0.80 kB/s | 1.20 kB/s | 66.7% |
| 4096 B | 1/10 | 10/10 | 0.84 kB/s | 1.25 kB/s | 67.2% |

Under burst transmission, delivery of multi-fragment bundles degrades
sharply; under paced transmission, matched to the modeled contact rate,
delivery is fully reliable at both sizes. We traced the burst-mode failure to
µD3TN's CSP CLA link-lifecycle management rather than to CSPCL itself: an
opportunistic link is created for a peer on first contact and torn down as
soon as it is idle, with the next arriving bundle re-triggering link
creation as though establishing a new peer. When bundles are transmitted
back-to-back, this teardown-and-recreate cycle can interrupt an
in-progress SFP reassembly on the receiving side, corrupting that bundle's
delivery. We ruled out CSPCL's own protocol-level timeouts as the cause,
isolating the issue to µD3TN's link management rather than to the shared
CSPCL library or its connection pool.

This result both validates the application-level delivery acknowledgement
described in Section III-A (corrupted or lost bundles are consistently
detected and reported as failures, not silently dropped) and characterizes
a concrete operating boundary for the pool/link mechanism: transmission
must be paced to the contact's nominal rate for multi-fragment bundles to
be delivered reliably through µD3TN's CSP CLA. Burst transmission, issuing
several bundles faster than the link can be re-established between them,
is the load condition under which this boundary is reached.

Paced throughput for these payloads reaches 66.7–67.2% of the modeled
ceiling — noticeably below the 83–94% observed for 64 B/256 B in
Section VI-A. We attribute this gap to a distinct issue in CSPCL's RDP
configuration: `cspcl.c` sets `csp_conf.rdp_max_window`, which sizes
libcsp's internal transmit/receive queues, but never calls
`csp_rdp_set_opt()`, the function that sets the RDP protocol's actual
flow-control window — which therefore remains at libcsp's default of 4
unacknowledged packets. A 1024 B bundle (5 SFP fragments) or 4096 B bundle
(18 fragments) both exceed this window, forcing the sender to block for a
real acknowledgement round-trip partway through a single bundle's
transmission — an interruption the ceiling model, which assumes
unconstrained protocol behavior, does not account for. 64 B and 256 B stay
within one or two fragments and never exhaust the window, consistent with
their closer tracking of the ceiling.

#### C. Store-and-Forward Recovery Under Node Disruption

We validated store-and-forward recovery under node failure in two
configurations. In an earlier two-node configuration using Hardy alone, one
node was killed outright while a bundle was in flight; the bundle was held
in local storage by the surviving peer and successfully delivered once the
killed node was restarted, confirming that a lost CSPCL connection triggers
BP's store-and-forward path rather than a silently dropped bundle.

We repeated this at node granularity on the full four-node chain by
terminating and restarting the `unibo-bp-cspcl` daemon for a few seconds
while bundles were in transit, rather
than merely interrupting the underlying link. This exercises node failure
more directly than a link-level interruption, since it discards the
daemon's own connection-pool state along with its CSP connection. Traffic
directed at the disrupted node during the outage was retained rather than
dropped, and delivery resumed and completed fully once the daemon
restarted.

---

## Notes / things to double check before submitting

- Latency figures (202ms/1241ms) vary somewhat run-to-run; the kB/s and %
  of ceiling figures were stable across every run and are the safer
  numbers to anchor the claim on.
- Items B.4 (Charon CAN-frame reassembly frequency), B.5 (beyond-4-node)
  are still untouched by this draft.
