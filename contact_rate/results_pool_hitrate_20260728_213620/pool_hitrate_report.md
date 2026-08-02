# Connection-pool hit rate under paced delivery

unibo-bp-cspcl outbound pool (node1 -> hardy), pace margin 1.5x,
CAN hops shaped to 50kbit/s, alice<->unibo shaped to 100kbit/s.
hits/misses/evictions/invalidations are diffs across this run only (the daemon's
pool is long-lived and shared across every run against it).

| payload (B) | delivered | hits | misses | evictions | invalidations | hit rate |
| --- | --- | --- | --- | --- | --- | --- |
| 1024 | 20/20 | 20 | 0 | 0 | 0 | 100.0% |
| 4096 | 20/20 | 60 | 0 | 0 | 0 | 100.0% |
