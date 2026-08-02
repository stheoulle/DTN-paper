# Paced-delivery reliability and throughput

CAN hops shaped to 50kbit/s; alice<->unibo shaped to 100kbit/s.
Elapsed time for achieved kB/s is anchored to vcan0's qdisc backlog
draining to zero (verified via `tc -s qdisc show dev vcan0`), not to
apps/receiver's own completion signal -- see script header for why.

| payload (B) | delivered | pace (ms) | drain (s) | achieved kB/s | ceiling kB/s | % of ceiling | result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1024 | 10/10 | 940 | 9.7 | 1.06 | 1.20 | 88.3% | PASS |
| 4096 | 10/10 | 3618 | 40.03 | 1.02 | 1.25 | 81.6% | PASS |
