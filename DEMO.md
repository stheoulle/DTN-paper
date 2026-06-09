# Full-stack demo: App1 → Charon → Alice → Unibo → Hardy → Bob → Charon → App2

All commands run from the **repo root** unless stated otherwise.

---

## Architecture recap

```
App1  ──TCP──  Charon(alice)  ──AAP2──  Node0(ud3tn + A-SABR)
                                               │ MTCP :4224
                                        Node1(Unibo + CSPCL)   CSP addr 1
                                               │ CAN / vcan0
                                        Node2(Hardy + TVR)     CSP addr 2
                                               │ CAN / vcan0
                                        Node3(ud3tn + CSPCL + A-SABR)  CSP addr 3
                                               │ AAP2
              Charon(bob)   ──AAP2──  ─────────┘
App2  ──TCP──  Charon(bob)
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

```bash
export UNIBO_BP_LIB=$(git rev-parse --show-toplevel)/unibo-dtn/unibo-bp/build/Unibo-BP/lib
cd cspcl/unibo-integration
# args: <csp_local_addr> <csp_port> <iface> <local_port> <unibo_workdir>
./build/unibo-bp-cspcl 1 10 can 2001 /tmp/unibo-node1
```

### T5 — Node2: Hardy BPA server

```bash
./hardy/target/release/hardy-bpa-server --config demo/hardy.yaml
```

### T6 — Node2: Hardy TVR routing agent

```bash
# Run from repo root so hardy-routes.txt path resolves correctly.
./hardy/target/release/hardy-tvr --config demo/hardy-tvr.toml
```

### T7 — Node3: bob uD3TN with CSPCL (BDM mode)

```bash
cd ud3tn
./build/posix/ud3tn \
  -e dtn://bob.dtn/ \
  -S /tmp/bob.aap2.socket \
  -s /tmp/bob.socket \
  -c "csp:3,10,can" \
  -d
```

### T8 — Node3: bob A-SABR BDM

```bash
source .venv/bin/activate
cd asabr_bdm
python main.py \
  ../demo/alice.cp \
  ../demo/bob-eid-map.json \
  --socket /tmp/bob.aap2.socket \
  -vv
```

### T9 — Charon alice (needs root for TUN)

```bash
export CHARON_SECRET=demo_secret
sudo -E ./charon/build/charon ./demo/charon-alice.conf
```

### T10 — Charon bob (needs root for TUN)

```bash
export CHARON_SECRET=demo_secret
sudo -E ./charon/build/charon ./demo/charon-bob.conf
```

---

## Phase 4 — Send a message

### T11 — App2: start the receiver (bob side)

```bash
./apps/receiver 4000
```

### T12 — App1: start the sender (alice side)

```bash
./apps/sender 10.0.0.2 4000
```

Traffic path: `sender` → kernel TUN `10.0.0.1` → Charon(alice) bundles to `dtn://bob.dtn/charon` → uD3TN(alice) A-SABR routes next-hop to Unibo → MTCP `:4225` → Unibo → CSPCL `:vcan0` (CSP 1→2) → Hardy → CSPCL `vcan0` (CSP 2→3) → uD3TN(bob) A-SABR delivers → Charon(bob) injects packet into TUN `10.0.0.2` → `receiver`.

---

## Cleanup

```bash
pkill -f "ud3tn|unibo-bp|hardy-bpa-server|hardy-tvr|charon"
sudo ip link del vcan0 2>/dev/null || true
rm -f /tmp/alice.aap2.socket /tmp/alice.socket /tmp/bob.aap2.socket /tmp/bob.socket
rm -rf /tmp/unibo-node1
```

---

## Troubleshooting

**BDM sees no dispatch events** — check that uD3TN was started with `-d` (BDM mode).

**Charon fails to open TUN** — `charon` must run as root or with `CAP_NET_ADMIN`. Use `sudo -E` to preserve the `CHARON_SECRET` env variable.

**CAN frames not moving** — verify `vcan0` is up (`ip link show vcan0`). Use `candump vcan0` in a spare terminal to watch raw frames.

**Hardy TVR routes not installing** — check that `hardy-bpa-server` is already running before starting `hardy-tvr`, and that the gRPC port `50051` is reachable.

**CSPCL-patched uD3TN fails to link** — confirm `libcsp/build/libcsp.a` exists and the sed substitution in Phase 0.3 replaced the hardcoded path correctly (`grep mathias cspcl/ud3tn-integration/ud3tn-cla-csp.patch` should return nothing).
