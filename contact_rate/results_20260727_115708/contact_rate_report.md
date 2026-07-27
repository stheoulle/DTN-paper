# Achieved throughput vs. modeled contact rate

CAN hops (unibo<->hardy, hardy<->bob) shaped to 50kbit/s;
alice<->unibo shaped to 100kbit/s. End-to-end, real 4-hop chain.

| payload (B) | delivered | mean latency (ms) | achieved kB/s | ceiling kB/s | % of ceiling | timeout used |
| --- | --- | --- | --- | --- | --- | --- |
| 64 | 20/20 | 911.171 | 0.42 | 0.67 | 62.7% | 15s |
| 256 | 4/20 | N/A | 0.04 | 1.02 | 3.9% | 26s |
