What Went Well
1. All components initialized correctly

alice ud3tn started, BPv7 configured, TCPCLv3 listening on :4224
bob ud3tn started, CSP CLA at addr=3 on can interface
alice and bob A-SABR BDMs both registered, loaded the same contact plan, mapped all 4 nodes (alice=0, unibo=1, hardy=2, bob=3)
2. TCP link alice ↔ unibo established (line 17-18)


TCPCLv3: Connected to "127.0.0.1:4225"
Handshake with "dtn://unibo.dtn/"
3. cspcl (unibo-node1, addr=1) ↔ hardy (addr=2) link established (line 208-211)

Link for csp_addr=2 created, contact added, RX thread started
4. cspcl forwarded all PDUs successfully (lines 287-336)

tx_id 123 → 147: every single tx success dst_csp=2; bundles from alice's charon reached the CAN interface
5. Both charon instances up and tunneling

charon-alice: tun0 at 10.0.0.1/30, sent bundles continuously (15:27:23 → 15:35:34), every Bundle sent! … Success
charon-bob: tun1 at 10.0.0.2/30, same pattern (15:27:31 → 15:35:44)
6. End-to-end delivery: 1000/1000 messages (lines 849-879)


recv … msg #1 … msg #12 … and 1000 messages total
sent … msg #1 … msg #14 … And 1000 messages total
The sender (10.0.0.1 side) reached the receiver (10.0.0.2 side).

What Failed
CRITICAL — Hardy rejects every frame from unibo's cspcl (lines 356–391)

WARN hardy_cspcl::runtime: dropping malformed frame from CspAddress { addr: 1, port: 51 }: unsupported frame version 159
This fires for every single bundle forwarded from alice → unibo → hardy, all the way to 15:33:34
version 159 = 0x9F — likely a CSP header version mismatch between unibo-bp-cspcl and hardy's hardy_cspcl CLA
The cspcl side reports tx success, meaning it sends the frame fine; hardy just rejects the CSP encapsulation format
Root cause: protocol incompatibility between cspcl/unibo-integration and hardy's CLA
MAJOR — Alice A-SABR drops all bundles with dispatch reason 5 (from line 50 onward)
Route IS found every time: contact 1067835984 (0→1), next hop = dtn://unibo.dtn/
But then immediately: Dropping bundle: dispatch reason 5
Reason 5 likely = TCPCLv3 CLA queue full or send failed — consistent with bundles piling up at unibo because hardy never accepts the next hop
MAJOR — Bob A-SABR drops all bundles with dispatch reason 3 (from line 455 onward)
Route IS found: contact 678578432 (3→2), next hop = dtn://hardy.dtn/
But: Dropping bundle: dispatch reason 3 — CSP CAN CLA to hardy not available / send failure
Return path bob → alice is entirely broken
MODERATE — Bob ud3tn RX buffer overflow every ~53 seconds (lines 422–430)

WARNING RX: RX buffer is full and does not clear. Resetting all parsers!
Fires at 15:27:57, 15:28:50, 15:29:44, 15:30:37 … consistently every 53 s
Caused by receiving unparseable CSP frames on the CAN interface that can never be consumed
Summary Table
Component	Status	Notes
alice ud3tn	OK	TCPCLv3 to unibo up
alice A-SABR	Routing OK, forwarding FAILED	Dispatch reason 5 on all bundles
cspcl (unibo-node1)	TX OK	All PDUs sent successfully to hardy
hardy BPA	FAILED	Rejects all frames from cspcl as "version 159"
bob ud3tn	Degraded	RX buffer overflow loop
bob A-SABR	Routing OK, forwarding FAILED	Dispatch reason 3 on all bundles
charon-alice	OK	Bundles sent to uD3TN successfully
charon-bob	OK	Bundles sent to uD3TN successfully
End-to-end (1000 msgs)	OK	Delivered, likely via local tun routing on single machine
Where to Look to Fix
The single root cause is the CSP frame version mismatch at the hardy ↔ cspcl boundary. Hardy expects a different CSP frame version than what unibo-bp-cspcl produces. Check:

The CSP version/header format used by cspcl/unibo-integration/build/unibo-bp-cspcl (look at how it constructs the CSP packet — port 51 is the destination port, and 0x9F is the first byte of the frame header)
The CSP frame parser in hardy_cspcl::runtime (what version does it expect?)
Whether both sides agree on CSP v1 vs v2 frame layout (the 2-bit version field in the CSP header maps to 0x9F >> 6 = 2, so hardy may expect version 2 but the framing itself is different)
Once hardy accepts frames from cspcl, the dispatch reason 5/3 drops and the RX buffer overflow should all resolve downstream.