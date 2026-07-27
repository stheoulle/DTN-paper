# Achieved throughput vs. modeled contact rate

CAN hops (unibo<->hardy, hardy<->bob) shaped to 50kbit/s;
alice<->unibo shaped to 100kbit/s. End-to-end, real 4-hop chain.

| payload (B) | delivered | mean latency (ms) | achieved kB/s | ceiling kB/s | % of ceiling | timeout used |
| --- | --- | --- | --- | --- | --- | --- |
| 64 | 14/40 | N/A | 0.05 | 0.67 | 7.5% | 19s |
| 256 | 10/40 | N/A | 0.05 | 1.02 | 4.9% | 51s |
