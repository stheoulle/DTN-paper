# Paced-delivery reliability and throughput

CAN hops shaped to 50kbit/s; alice<->unibo shaped to 100kbit/s.
Elapsed time for achieved kB/s is anchored to vcan0's qdisc backlog
draining to zero (verified via `tc -s qdisc show dev vcan0`), not to
apps/receiver's own completion signal -- see script header for why.

| payload (B) | delivered | pace (ms) | drain (s) | achieved kB/s | ceiling kB/s | % of ceiling | result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1024 | 10/10 | 1282 | 12.77 | 0.8 | 1.20 | 66.7% | PASS |
| 4096 | 10/10 | 4934 | 48.3 | 0.85 | 1.25 | 68.0% | PASS |
