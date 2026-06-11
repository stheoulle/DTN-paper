# Full-stack demo: App1 → Charon → Alice → Unibo → Hardy → Bob → Charon → App2

All commands run from the **repo root** unless stated otherwise.

---

## Architecture recap

```
App1  ──UDP──  Charon(alice)  ──AAP2──  Node0(ud3tn + A-SABR)
                                               │ BP7/TCPCLv3 :4224
                                        Node1(Unibo + CSPCL)   CSP addr 1
                                               │ BP7/CSP+RDP/CAN (vcan0)
                                        Node2(Hardy + A-SABR)  CSP addr 2
                                               │ BP7/CSP+RDP/CAN (vcan0)
                                        Node3(ud3tn + CSPCL)   CSP addr 3
                                               │ AAP2
              Charon(bob)   ──AAP2──  ─────────┘
App2  ──UDP──  Charon(bob)
```

**Ports and sockets**

| Component | Socket / port |
|-----------|---------------|
| Node0 AAP2 | `/tmp/alice.aap2.socket` |
| Node0 TCPCLv3 | `*:4224` |
| Node1 Unibo TCPCLv3 (incoming from alice) | `*:4225` |
| Node2 Hardy gRPC | `[::1]:50051` |
| Node2 Hardy CSPCL CAN (CSP addr 2) | `vcan0` |
| Node3 AAP2 | `/tmp/bob.aap2.socket` |
| Charon alice TUN | `10.0.0.1/32` |
| Charon bob TUN | `10.0.0.2/32` |
| App1 sender target | `10.0.0.2:4000` |
| App2 receiver | `*:4000` |

---

## Phase 1 — One-time system setup

```bash
# vcan0 virtual CAN bus (persists until reboot)
sudo modprobe vcan
sudo ip link add dev vcan0 type vcan
sudo ip link set up vcan0
ip link show vcan0   # should show UP

# Network namespaces for Charon (alice and bob run on the same machine).
# Without this, 10.0.0.2 is a local address on tun1 and the kernel delivers
# packets there directly, bypassing Charon alice and the entire DTN stack.
# Each namespace sees only its own TUN interface, forcing traffic through Charon.
sudo ip netns add alice_ns
sudo ip netns add bob_ns
```

---

## Phase 2 — Config files

All config files are pre-created in `demo/`.  Review and adjust if needed:

| File | Purpose |
|------|---------|
| `demo/alice.cp` | A-SABR contact plan (4 nodes, shared by both BDMs) |
| `demo/alice-eid-map.json` | EID→CLA map for Node0's BDM |
| `demo/bob-eid-map.json` | EID→CLA map for Node3's BDM |
| `demo/charon-alice.conf` | Charon config, alice side |
| `demo/charon-bob.conf` | Charon config, bob side |
| `demo/hardy.yaml` | Hardy BPA server config (Node2) |
| `demo/hardy-tvr.toml` | Hardy TVR routing agent config |
| `demo/hardy-routes.txt` | Hardy static contact plan |

---

## Phase 3 — Start the stack

Open a terminal per component (or use `tmux`).  Start in the order listed.

### T1 — Node0: alice uD3TN (BDM mode)

```bash
cd $(git rev-parse --show-toplevel)/ud3tn
./build/posix/ud3tn \
  -e dtn://alice.dtn/ \
  -S /tmp/alice.aap2.socket \
  -s /tmp/alice.socket \
  -c "tcpclv3:*,4224" \
  -d
```

### T2 — Node0: alice A-SABR BDM

```bash
source .venv/bin/activate
cd asabr_bdm
python main.py \
  ../demo/alice.cp \
  ../demo/alice-eid-map.json \
  --socket /tmp/alice.aap2.socket \
  -vv
```

### T3 — Node1: Unibo BP core

```bash
export UNIBO_BP_BIN=$(git rev-parse --show-toplevel)/unibo-dtn/unibo-bp/build/Unibo-BP/bin
mkdir -p /tmp/unibo-node1 && cd /tmp/unibo-node1
$UNIBO_BP_BIN/unibo-bp start \
  --set-storage-size 50000000 \
  --dtn-admin dtn://unibo.dtn/ \
  --ipn-admin ipn:1.0 \
  --daemon
```

Then configure routing on Node1 (run once, same terminal):

```bash
REFERENCE_TIME=$($UNIBO_BP_BIN/unibo-bp-utility --get-utc-time +0)

$UNIBO_BP_BIN/unibo-bp-admin region home --register-node ipn:1.0
$UNIBO_BP_BIN/unibo-bp-admin region home --register-node ipn:2.0

$UNIBO_BP_BIN/unibo-bp-admin range add \
  --start-time +0 --end-time +86400 \
  --sender ipn:1.0 --receiver ipn:2.0 --owlt 0 \
  --reference-time "$REFERENCE_TIME"
$UNIBO_BP_BIN/unibo-bp-admin range add \
  --start-time +0 --end-time +86400 \
  --sender ipn:2.0 --receiver ipn:1.0 --owlt 0 \
  --reference-time "$REFERENCE_TIME"

$UNIBO_BP_BIN/unibo-bp-admin contact add \
  --start-time +0 --end-time +86400 \
  --sender ipn:1.0 --receiver ipn:2.0 \
  --xmit-rate 50000 --reference-time "$REFERENCE_TIME"
$UNIBO_BP_BIN/unibo-bp-admin contact add \
  --start-time +0 --end-time +86400 \
  --sender ipn:2.0 --receiver ipn:1.0 \
  --xmit-rate 50000 --reference-time "$REFERENCE_TIME"

$UNIBO_BP_BIN/unibo-bp-admin routing static add \
  --destination dtn://hardy.dtn/* --gateway ipn:2.0
$UNIBO_BP_BIN/unibo-bp-admin routing static add \
  --destination dtn://bob.dtn/* --gateway ipn:2.0
```

### T3b — Node1: Unibo TCPCLv3 CLA (link toward alice)

```bash
# Start the TCPCLv3 CLA daemon (connects to the unibo-bp core already running)
$UNIBO_BP_BIN/unibo-bp-tcpcl --daemon
# Open a TCPCLv3 induct so alice can connect in
$UNIBO_BP_BIN/unibo-bp-admin tcpcl induct add --port 4225
```

### T4 — Node1: Unibo CSPCL daemon (CAN bridge toward Hardy)

> **Start this after T5 (Hardy).** The CSP connection attempt fires immediately on startup; if Hardy isn't listening yet it will fail and the daemon will crash.

```bash
# Build once (or after any cspcl source change)
export DTN_ROOT=$(git rev-parse --show-toplevel)
export UNIBO_BP_LIB=$DTN_ROOT/unibo-dtn/unibo-bp/build/Unibo-BP/lib
export LIBCSP_BUILD=$DTN_ROOT/libcsp/build

cd cspcl/unibo-integration
mkdir -p build
gcc -O2 -Wall -Wextra \
  src/cspcl_daemon.c ../src/cspcl.c \
  -o build/unibo-bp-cspcl \
  -I../src \
  -I$DTN_ROOT/unibo-dtn/unibo-bp/include \
  -I$DTN_ROOT/libcsp/include \
  -I$DTN_ROOT/libcsp/build/include \
  -L$UNIBO_BP_LIB \
  -Wl,-rpath,$UNIBO_BP_LIB \
  -lunibo-bp-api \
  $LIBCSP_BUILD/libcsp.a \
  -lzmq -lpthread -lm \
  -lsocketcan
  

# args: <csp_local_addr> <csp_port> <iface> <local_port> <unibo_workdir>
./build/unibo-bp-cspcl 1 10 can 2001 /tmp/unibo-node1
```

### T5 — Node2: Hardy BPA server

```bash
# Build once (or after any libcsp/cspcl source change)
DTN_ROOT=$(git rev-parse --show-toplevel)
cd $DTN_ROOT/hardy
# Pass CSP paths inline so they reach the cspcl-sys build script regardless of shell state
CSP_REPO_DIR=$DTN_ROOT/libcsp CSP_BUILD_DIR=$DTN_ROOT/libcsp/build \
  cargo build --release --features cspcl

cd ..

# Run
$DTN_ROOT/hardy/target/release/hardy-bpa-server --config $DTN_ROOT/demo/hardy.yaml
```

### T6 — Node3: bob uD3TN with CSPCL (BDM mode)

```bash
cd ud3tn
./build/posix/ud3tn \
  -e dtn://bob.dtn/ \
  -S /tmp/bob.aap2.socket \
  -s /tmp/bob.socket \
  -c "csp:3,10,can" \
  -d
```

### T7 — Node3: bob A-SABR BDM

```bash
source .venv/bin/activate
cd asabr_bdm
python main.py \
  ../demo/alice.cp \
  ../demo/bob-eid-map.json \
  --socket /tmp/bob.aap2.socket \
  -vv
```

### T8 — Charon alice (needs root for TUN)

Runs inside `alice_ns` so only `tun0` (10.0.0.1) exists there — the kernel cannot shortcut to `tun1`.
Unix sockets in `/tmp` are accessible from any network namespace.

```bash
sudo ip netns exec alice_ns \
  env CHARON_SECRET=demo_secret \
  $(pwd)/charon/build/charon $(pwd)/demo/charon-alice.conf
```

### T9 — Charon bob (needs root for TUN)

```bash
sudo ip netns exec bob_ns \
  env CHARON_SECRET=demo_secret \
  $(pwd)/charon/build/charon $(pwd)/demo/charon-bob.conf
```

---

## Phase 4 — Send a message

> T8 and T9 (Charon alice and bob) must be running before this phase.

### T10 — App2: receiver on bob side

Runs inside `bob_ns` so it binds to the `tun1` address space.

```bash
sudo ip netns exec bob_ns $(pwd)/apps/receiver 4000
```

### T11 — App1: sender on alice side

Runs inside `alice_ns`. Only `tun0` (10.0.0.1/30) exists there, so 10.0.0.2 is not a local address and the kernel routes it through `tun0` → Charon alice.

```bash
sudo ip netns exec alice_ns $(pwd)/apps/sender 10.0.0.2 4000
```

Full traffic path:
```
sender (alice_ns) ─UDP/IP─▶ tun0 ─IP─▶ Charon(alice) ─BP7/AAP2─▶ uD3TN(alice)
  ─BP7/TCPCLv3─▶ Unibo ─BP7/CSP+RDP/CAN (addr 1→2)─▶ Hardy
  ─BP7/CSP+RDP/CAN (addr 2→3)─▶ uD3TN(bob) ─BP7/AAP2─▶ Charon(bob) ─IP─▶ tun1 ─UDP/IP─▶ receiver (bob_ns)

(A-SABR is the routing algorithm used by uD3TN(alice) and Hardy to select the next hop.)
```

Return path is symmetric (Charon bob → `dtn://alice.dtn/charon` → Charon alice).

> **Note on Hardy logs**: Hardy logs bundle reception, routing, and forwarding at `debug` level. A silent Hardy terminal with `log-level: info` means it is working correctly.

---
### Test Alice's side without charon

```bash
source .venv/bin/activate
python3 -m ud3tn_utils.aap2.bin.aap2_receive \
  --socket /tmp/bob.aap2.socket \
  --agentid charon -v
```

In another terminal, generate one ICMP packet from inside alice_ns:
```bash
sudo ip netns exec alice_ns ping -c 1 10.0.0.2
```
If Charon alice is working, aap2_receive will print a bundle (binary ICMP payload). The ping itself will hang (no reply, since Charon bob isn't running) 

### Quick connectivity test (no Charon required)

To verify the DTN chain alone without the TUN layer:

```bash
# Terminal A — receive on bob
source .venv/bin/activate
python3 -m ud3tn_utils.aap2.bin.aap2_receive \
  --socket /tmp/bob.aap2.socket --agentid test -v -c 1

# Terminal B — send from alice
source .venv/bin/activate
echo "hello DTN" | python3 -m ud3tn_utils.aap2.bin.aap2_send \
  --socket /tmp/alice.aap2.socket dtn://bob.dtn/test
```

---

## Cleanup

```bash
pkill -f "ud3tn|unibo-bp|hardy-bpa-server|hardy-tvr|charon"
sudo ip link del vcan0 2>/dev/null || true
sudo ip netns del alice_ns 2>/dev/null || true
sudo ip netns del bob_ns 2>/dev/null || true
rm -f /tmp/alice.aap2.socket /tmp/alice.socket /tmp/bob.aap2.socket /tmp/bob.socket
rm -rf /tmp/unibo-node1
```

---

## Troubleshooting

**BDM sees no dispatch events** — check that uD3TN was started with `-d` (BDM mode).

**Charon fails to open TUN** — `charon` must run as root or with `CAP_NET_ADMIN`. Use `sudo -E` to preserve the `CHARON_SECRET` env variable.

**CAN frames not moving** — verify `vcan0` is up (`ip link show vcan0`). Use `candump vcan0` in a spare terminal to watch raw frames.

**Hardy A-SABR fails to initialise** — check that `contact-plan-path` in `demo/hardy.yaml` resolves correctly (run from repo root) and that `local-node-id: "ipn:2.0"` matches a node declared in the contact plan.

**CSPCL-patched uD3TN fails to link** — confirm `libcsp/build/libcsp.a` exists and the sed substitution in Phase 0.3 replaced the hardcoded path correctly (`grep mathias cspcl/ud3tn-integration/ud3tn-cla-csp.patch` should return nothing).
