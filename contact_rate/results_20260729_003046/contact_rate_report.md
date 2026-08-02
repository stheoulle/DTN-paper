# Achieved throughput vs. modeled contact rate

CAN hops (unibo<->hardy, hardy<->bob) shaped to 50kbit/s;
alice<->unibo shaped to 100kbit/s. End-to-end, real 4-hop chain.

| payload (B) | delivered | mean latency (ms) | achieved kB/s | ceiling kB/s | % of ceiling | timeout used |
| --- | --- | --- | --- | --- | --- | --- |
| 64 | 10/10 | 459.267 | 0.64 | 0.67 | 95.5% | 15s |
| 256 | 10/10 | 1071.052 | 0.85 | 1.02 | 83.3% | 15s |
