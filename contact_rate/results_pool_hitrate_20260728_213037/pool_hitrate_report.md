# Connection-pool hit rate under paced delivery

unibo-bp-cspcl outbound pool (node1 -> hardy), pace margin 1.5x,
CAN hops shaped to 50kbit/s, alice<->unibo shaped to 100kbit/s.
hits/misses/evictions/invalidations are diffs across this run only (the daemon's
pool is long-lived and shared across every run against it).

| payload (B) | delivered | hits | misses | evictions | invalidations | hit rate |
| --- | --- | --- | --- | --- | --- | --- |
| 1024 | 10/10 | 9 | 1 | 0 | 0 | 90.0% |
| 4096 | 10/10 | 30 | 0 | 0 | 0 | 100.0% |
