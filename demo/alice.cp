# Full 4-node demo contact plan
# Used by the A-SABR BDMs on Node0 (alice) and Node3 (bob).

node 0 alice
node 1 unibo
node 2 hardy
node 3 bob

# alice <-> unibo  (TCP/MTCP, unlimited window)
contact 0 1 0 9999999999 100000 1
contact 1 0 0 9999999999 100000 1

# unibo <-> hardy  (CAN/vcan0 via CSPCL, CSP addr 1 <-> 2)
contact 1 2 0 9999999999 50000 5
contact 2 1 0 9999999999 50000 5

# hardy <-> bob    (CAN/vcan0 via CSPCL, CSP addr 2 <-> 3)
contact 2 3 0 9999999999 50000 5
contact 3 2 0 9999999999 50000 5
