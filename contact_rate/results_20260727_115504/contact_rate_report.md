# Achieved throughput vs. modeled contact rate

CAN hops (unibo<->hardy, hardy<->bob) shaped to 50kbit/s;
alice<->unibo shaped to 100kbit/s. End-to-end, real 4-hop chain.

| payload (B) | delivered | mean latency (ms) | achieved kB/s | ceiling kB/s | % of ceiling | timeout used |
| --- | --- | --- | --- | --- | --- | --- |
| 64 | 0/40 | N/A | 0 | 0.67 | 0.0% | 19s |
| 256 | 0/40 | N/A | 0 | 1.02 | 0.0% | 51s |
