Why the 1000 messages bypassed everything
Look at the tun setup and the network topology on the same machine:


charon-alice:  ip addr add 10.0.0.1/30 dev tun0
charon-bob:    ip addr add 10.0.0.2/30 dev tun1
Both TUN interfaces are on the same machine. That means the Linux kernel's local routing table has 10.0.0.2 as a local address (it lives on tun1).

When the sender does:


./apps/sender 10.0.0.2 4000
The kernel looks up 10.0.0.2, sees it's a local address assigned to tun1, and delivers the packet directly — it never enters tun0, so charon-alice never captures it, no bundle is ever created, and the entire DTN stack is bypassed. The receiver just accepts a plain TCP connection locally.

This also explains why the receiver sees:


connection from 10.0.0.2:36822
The source IP is 10.0.0.2 — the kernel routed it via the tun1 subnet, keeping everything local.

And it explains why all 1000 messages arrived at the same timestamp t=1781011673.698-699 (within 1ms) — there was zero DTN latency because there was no DTN involved.

What a real end-to-end test requires
For the traffic to actually traverse the DTN path, the sender and receiver need to be in separate network namespaces (or on separate machines), so 10.0.0.2 is not reachable locally. Then:

Sender's packet enters tun0 → captured by charon-alice
Charon wraps it in a bundle → uD3TN(alice) → TCPCLv3 → unibo → vCAN → hardy → CAN → uD3TN(bob)
charon-bob injects the packet into tun1 → receiver at 10.0.0.2 gets it
In your current single-machine setup, the OS short-circuits step 1 entirely, so none of the transport issues (hardy frame rejection, dispatch reason 5/3 drops) have any impact on the sender/receiver test.

The 1000-message test is therefore not a valid validation of the end-to-end DTN path — it only proves TCP works locally.

-------------
Hardy's cspcl CLA wraps every CSP packet in its own custom envelope before the bundle data. Unibo's cspcl sends raw BP7 bundles with no envelope at all.

Hardy expects (hardy/cspcl/src/frame.rs):


[0x01 = version] [type byte] [payload...]
It checks if input[0] != VERSION (VERSION = 1) and rejects anything else.

Unibo sends (cspcl/src/cspcl.c):


[0x9F ...] ← raw BP7 bundle, CBOR indefinite-length array marker
No version byte, no type byte — just the raw bundle directly over CSP SFP.

So hardy reads the first byte of the CBOR bundle 0x9F = 159 decimal as the version field → "unsupported frame version 159".