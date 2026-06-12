# PolarFire RISC-V Experiment

Distributed variant of the 4-node demo across three physical machines.
Follow the README.md and DEMO.md first to verify the stack works end-to-end on a
single machine, then use this document to split it across hardware.

---

## Topology

```bash
         VM (x86)                 PolarFire 1              PolarFire 2
┌────────────────────┐   NET   ┌──────────────┐  CAN BUS  ┌──────────────────────────────────┐
│  App1              │  TCP/IP │              │  (can0 ↔   │  (can0)                          │
│  Charon (alice)    │◄───────►│  Unibo-BP    │   can0)    │  Hardy (A-SABR)                  │
│  uD3TN (alice)     │         │  TCPCLv3 CLA │◄──────────►│  CSPCL                           │
│  A-SABR BDM        │         │  CSPCL CLA   │            │    (can0)                        │
└────────────────────┘         └──────────────┘            │  uD3TN (bob)  A-SABR BDM         │
                                                           │  CSPCL / Charon (bob)  /  App2   │
                                                           └──────────────────────────────────┘
```

| Node | Machine | CSP addr | CAN interface |
| ------ | --------- | ---------- | --------------- |
| alice (uD3TN) | VM | — | — |
| unibo (Unibo-BP) | PolarFire 1 | 1 | `can0` (real CAN to PF2) |
| hardy | PolarFire 2 | 2 | `can0` (real CAN, shared with bob and PF1) |
| bob (uD3TN) | PolarFire 2 | 3 | `can0` (same real CAN bus) |

**Key differences from the single-machine demo:**

- Alice ↔ Unibo: TCP/IP over a real network link instead of loopback.
- Unibo ↔ Hardy ↔ Bob: all three nodes share the single real CAN bus (`can0` on PF2).
- No virtual CAN needed on PF2.
- All components on PF1 and PF2 must be cross-compiled for RISC-V.
- Each machine runs its own copy of the relevant config files and sockets.

---

## 1. Prerequisites

### VM (x86)

Same as the single-machine demo (Python venv, ud3tn, charon, asabr_bdm).
No rebuild required.

### PolarFire 1 and PolarFire 2

Install the RISC-V cross-toolchain on your build machine (x86):

```bash
sudo pacman -S riscv64-linux-gnu-gcc riscv64-linux-gnu-binutils
sudo pacman -S python python-pip   # for libcsp waf build
```

Install the Rust RISC-V target:

```bash
rustup target add riscv64gc-unknown-linux-gnu
# Also install a RISC-V linker for Rust:
# In ~/.cargo/config.toml add:
# [target.riscv64gc-unknown-linux-gnu]
# linker = "riscv64-linux-gnu-gcc"
```

Add to `~/.cargo/config.toml`:

```toml
[target.riscv64gc-unknown-linux-gnu]
linker = "riscv64-linux-gnu-gcc"
```

On each PolarFire, verify the following kernel modules are available
(or compiled in):

```bash
modprobe can
modprobe can_raw
modprobe can_dev
```

---

## 2. CAN Hardware Setup

### Physical CAN bus (between PF1 and PF2)

Wire the CAN_H / CAN_L signals between the two boards' CAN transceivers.
Place **120 Ω termination resistors** between CAN_H and CAN_L at **both ends**.

On **PolarFire 1** and **PolarFire 2** (same command on each):

```bash
# Set bitrate — both boards MUST use the same value
 ip link set can0 type can bitrate 500000
 ip link set up can0
ip link show can0   # should show UP
```

Verify frames flow end-to-end before starting any software:

```bash
# PF2 — listen
candump can0

# PF1 — send one frame
cansend can0 001#DEADBEEF
# PF2 should print the frame
```

---

## 3. Cross-Compilation

Perform all build steps on your x86 build machine, then copy binaries to the boards.

### 3.1 libsocketcan (for PF1 and PF2)

libsocketcan has no Arch RISC-V cross package and must be built first — libcsp's
CAN driver includes `libsocketcan.h` at compile time.

```bash
git clone https://github.com/linux-can/libsocketcan.git
cd libsocketcan
autoreconf -i
./configure --host=riscv64-linux-gnu \
  --prefix=$(pwd)/../libsocketcan-riscv
make install
cd ..
```

The headers land in `libsocketcan-riscv/include/` and the static library in
`libsocketcan-riscv/lib/libsocketcan.a`.

### 3.2 libcsp (for PF1 and PF2)

waf reads the compiler from the `CC`/`AR` environment variables for cross-compilation.
Do **not** pass `--enable-if-zmqhub` — zmq is not needed on the boards and has no
RISC-V cross package on Arch. Use `--out=build-riscv` to keep the x86 build intact.
Pass the libsocketcan headers via `CPPFLAGS`.

```bash
cd libcsp
CC=riscv64-linux-gnu-gcc AR=riscv64-linux-gnu-ar \
  CPPFLAGS="-I$(pwd)/../libsocketcan-riscv/include" \
  python3.11 waf configure \
    --enable-can-socketcan \
    --enable-rdp \
    --out=build-riscv
python3.11 waf build --out=build-riscv
cd ..
```

The built static library is `libcsp/build-riscv/libcsp.a` (RISC-V ELF).

### 3.3 uD3TN with CSPCL (for PF2 — bob node)

```bash
cd ud3tn
make clean
make posix \
  TOOLCHAIN_POSIX=riscv64-linux-gnu- \
  DISABLE_JSON=1 \
  DISABLE_SQLITE_STORAGE=1 \
  LIBCSP_BUILD_INCLUDE=/home/light/Documents/DO5/DTN-paper/libcsp/build-riscv/include
# binary: build/posix/ud3tn
cd ..
```

`TOOLCHAIN_POSIX` is the prefix ud3tn's build system uses for all tools (gcc, ar, ranlib…).
Passing `CC=` directly has no effect here. The `make clean` is required if you
previously built for x86 — without it make sees the existing artifacts and does nothing.
`DISABLE_JSON=1` and `DISABLE_SQLITE_STORAGE=1` skip the jansson and sqlite3
dependencies, neither of which has a RISC-V cross package on Arch. Both features
are unused when running in BDM mode.
`LIBCSP_BUILD_INCLUDE` points the compiler at the RISC-V build's `csp_autoconfig.h`
(which does NOT define `CSP_HAVE_LIBZMQ`), ensuring the zmqhub code is skipped
at compile time. Without this, the x86 autoconfig header is used and the linker
fails trying to find `csp_zmqhub_init` in the RISC-V `libcsp.a`.

The LDFLAGS line in `ud3tn/mk/posix.mk` already points to `libcsp/build-riscv` and
`libsocketcan-riscv/lib` (patched above) and has `-lzmq` removed.

### 3.4 Unibo-BP core libraries (for PF1)

Unibo-BP is a CMake project. Cross-compile it into a separate build directory so
the x86 build is not overwritten. A toolchain file is provided at
`unibo-dtn/unibo-bp/riscv64-linux-gnu.cmake`.

```bash
cd unibo-dtn/unibo-bp
cmake \
  -DCMAKE_TOOLCHAIN_FILE=riscv64-linux-gnu.cmake \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DWITH_MANPAGE_GENERATION=OFF \
  -S . -B build-riscv
cmake --build build-riscv -- -j$(nproc)
cd ../..
```

`WITH_MANPAGE_GENERATION=OFF` avoids a pod2man host-tool dependency that breaks
cross builds. The built libraries land in `build-riscv/Unibo-BP/lib/`.

### 3.5 CSPCL unibo daemon (for PF1)

```bash
DTN_ROOT=$(pwd)
UNIBO_BP_LIB=$DTN_ROOT/unibo-dtn/unibo-bp/build-riscv/Unibo-BP/lib
LIBCSP_BUILD=$DTN_ROOT/libcsp/build-riscv

cd cspcl/unibo-integration && mkdir -p build
riscv64-linux-gnu-gcc -O2 -Wall -Wextra \
  src/cspcl_daemon.c ../src/cspcl.c \
  -o build/unibo-bp-cspcl-riscv \
  -I../src \
  -I$DTN_ROOT/unibo-dtn/unibo-bp/include \
  -I$DTN_ROOT/unibo-dtn/unibo-bp/export/include \
  -I$DTN_ROOT/libcsp/include \
  -I$DTN_ROOT/libcsp/build-riscv/include \
  -L$UNIBO_BP_LIB \
  -Wl,--rpath-link,$UNIBO_BP_LIB \
  -Wl,-rpath,/opt/unibo-bp/lib \
  -lunibo-bp-api $LIBCSP_BUILD/libcsp.a \
  -L$DTN_ROOT/libsocketcan-riscv/lib -lsocketcan -lpthread -lm
cd ../..
```

`--rpath-link` lets the linker resolve transitive `.so` dependencies (all the internal
unibo-bp libs that `libunibo-bp-api.so` depends on) without embedding a build-machine
path in the binary. `-rpath` bakes `/opt/unibo-bp/lib` as the runtime search path into
the binary — the libraries must be present at that path on PF1 before the daemon starts.

**Deploying to PF1** (run from the build machine, replace `pf1` with the board's hostname or IP):

```bash
# Create the runtime library directory on PF1
ssh pf1 "sudo mkdir -p /opt/unibo-bp/lib"

# Copy all unibo-bp shared libraries
scp unibo-dtn/unibo-bp/build-riscv/Unibo-BP/lib/*.so* pf1:/opt/unibo-bp/lib/

# Copy the CSPCL daemon binary
scp cspcl/unibo-integration/build/unibo-bp-cspcl-riscv pf1:~/

# Refresh the dynamic linker cache on PF1
ssh pf1 "sudo ldconfig /opt/unibo-bp/lib"
```

Also copy the unibo-bp executables if you need `unibo-bp`, `unibo-bp-admin`, and
`unibo-bp-tcpcl` on PF1:

```bash
scp unibo-dtn/unibo-bp/build-riscv/Unibo-BP/bin/* pf1:~/
```

### 3.6 Hardy BPA server (for PF2)

```bash
cd hardy
CSP_REPO_DIR=$(pwd)/../libcsp \
CSP_BUILD_DIR=$(pwd)/../libcsp/build \
  cargo build --release \
    --target riscv64gc-unknown-linux-gnu \
    -p hardy-bpa-server \
    --features cspcl
# binary: target/riscv64gc-unknown-linux-gnu/release/hardy-bpa-server
cd ..
```

### 3.7 Charon (for PF2 — bob side)

```bash
cd charon
make CC=riscv64-linux-gnu-gcc
# binary: build/charon
cd ..
```

### 3.8 asabr_bdm and A-SABR-Python (for PF2)

If PF2 runs a full Linux distribution with Python 3.10+, install natively on the board:

```bash
# On PF2
pip3 install maturin
git clone https://github.com/theotchlx/A-SABR-Python && cd A-SABR-Python
git checkout feat/asabr-bdm && maturin develop && cd ..
git clone https://github.com/theotchlx/asabr_bdm
```

Otherwise, build a self-contained wheel with `maturin build --target riscv64gc-unknown-linux-gnu`
and transfer it.

---

## 4. Config File Changes

Copy the `demo/` directory to each machine and adjust per the sections below.

### 4.1 VM — `demo/alice-eid-map.json`

Change the TCPCLv3 CLA address from the loopback to PF1's real IP:

```json
{
    "dtn://alice.dtn/": {"name": "alice", "cla_addr": null},
    "dtn://unibo.dtn/": {"name": "unibo", "cla_addr": "tcpclv3:<PF1_IP>:4225"},
    "dtn://hardy.dtn/": {"name": "hardy", "cla_addr": null},
    "dtn://bob.dtn/":   {"name": "bob",   "cla_addr": null}
}
```

Replace `<PF1_IP>` with PolarFire 1's actual IP address on the network shared with the VM.

Everything else on the VM (alice uD3TN, asabr_bdm, charon, network namespaces) is
identical to the single-machine demo.

### 4.2 PolarFire 1 — Unibo

No file-based config changes: the TCPCLv3 induct already listens on all interfaces
(`*:4225`).  The CSPCL daemon argument that specifies the CAN interface must change
from `can` (which mapped to `vcan0` in the demo) to the real CAN interface name:

```bash
# Demo command (vcan):
./unibo-bp-cspcl 1 10 can 2001 /tmp/unibo-node1

# PF1 command (real CAN):
./unibo-bp-cspcl 1 10 can0 2001 /tmp/unibo-node1
```

### 4.3 PolarFire 2 — Hardy

Hardy uses a single CLA on `can0`, with both unibo and bob declared as peers.
All three nodes (unibo, hardy, bob) share the same physical CAN bus.

Create `demo/hardy-pf.yaml` (copy `demo/hardy.yaml` and replace the `clas` section):

```yaml
node-ids: ["dtn://hardy.dtn/", "ipn:2.0"]
log-level: info

grpc:
  address: "[::1]:50051"
  services:
    - application
    - cla
    - service

storage:
  metadata:
    type: memory
  bundle:
    type: memory

asabr:
  protocol-id: "asabr"
  router: "SpsnHybridParenting"
  contact-plan-path: "demo/alice.cp"
  local-node-id: "ipn:2.0"
  eid-map:
    "dtn://alice.dtn/": 0
    "dtn://unibo.dtn/": 1
    "dtn://hardy.dtn/": 2
    "dtn://bob.dtn/": 3

clas:
  - name: cspcl-can0
    type: cspcl
    local-addr: 2
    port: 10
    interface: can
    interface-name: can0
    peers:
      - node-id: "dtn://unibo.dtn/"
        addr: 1
        port: 10
      - node-id: "dtn://bob.dtn/"
        addr: 3
        port: 10
```

### 4.4 PolarFire 2 — Bob uD3TN

Change the CAN interface from the demo's `can` to the real `can0`:

```bash
# Demo command:
./ud3tn -e dtn://bob.dtn/ -S /tmp/bob.aap2.socket -s /tmp/bob.socket -c "csp:3,10,can" -d

# PF2 command:
./ud3tn -e dtn://bob.dtn/ -S /tmp/bob.aap2.socket -s /tmp/bob.socket -c "csp:3,10,can0" -d
```

### 4.5 Network namespace for Charon (PF2)

The `bob_ns` network namespace must be created on PF2, not on the VM:

```bash
# On PF2
 ip netns add bob_ns
```

---

## 5. Startup Sequence

Start components in the order listed.  Each component runs on the machine indicated.

### Step 1 — VM: alice uD3TN + A-SABR BDM

```bash
# T1
cd ud3tn
./build/posix/ud3tn \
  -e dtn://alice.dtn/ \
  -S /tmp/alice.aap2.socket \
  -s /tmp/alice.socket \
  -c "tcpclv3:*,4224" \
  -d

# T2
source .venv/bin/activate
cd asabr_bdm
python main.py \
  ../demo/alice.cp \
  ../demo/alice-eid-map.json \
  --socket /tmp/alice.aap2.socket \
  -vv
```

### Step 2 — PolarFire 2: Hardy BPA server

Start Hardy before Unibo's CSPCL daemon, so it is listening when the first CSP
connection attempt arrives.

```bash
# T3 (PF2)
./hardy-bpa-server --config demo/hardy-pf.yaml
```

### Step 3 — PolarFire 1: Unibo-BP core + CLAs

```bash
# T4 (PF1) — Unibo core
mkdir -p /tmp/unibo-node1 && cd /tmp/unibo-node1
unibo-bp start \
  --set-storage-size 50000000 \
  --dtn-admin dtn://unibo.dtn/ \
  --ipn-admin ipn:1.0 \
  --daemon

# Configure routing (once)
REFERENCE_TIME=$(unibo-bp-utility --get-utc-time +0)
unibo-bp-admin region home --register-node ipn:1.0
unibo-bp-admin region home --register-node ipn:2.0
unibo-bp-admin range add --start-time +0 --end-time +86400 \
  --sender ipn:1.0 --receiver ipn:2.0 --owlt 0 --reference-time "$REFERENCE_TIME"
unibo-bp-admin range add --start-time +0 --end-time +86400 \
  --sender ipn:2.0 --receiver ipn:1.0 --owlt 0 --reference-time "$REFERENCE_TIME"
unibo-bp-admin contact add --start-time +0 --end-time +86400 \
  --sender ipn:1.0 --receiver ipn:2.0 --xmit-rate 50000 --reference-time "$REFERENCE_TIME"
unibo-bp-admin contact add --start-time +0 --end-time +86400 \
  --sender ipn:2.0 --receiver ipn:1.0 --xmit-rate 50000 --reference-time "$REFERENCE_TIME"
unibo-bp-admin routing static add --destination dtn://hardy.dtn/* --gateway ipn:2.0
unibo-bp-admin routing static add --destination dtn://bob.dtn/* --gateway ipn:2.0

# T5 (PF1) — TCPCLv3 CLA (alice connects inbound on port 4225)
unibo-bp-tcpcl --daemon
unibo-bp-admin tcpcl induct add --port 4225

# T6 (PF1) — CSPCL CLA (CAN bridge toward Hardy on PF2)
./unibo-bp-cspcl 1 10 can0 2001 /tmp/unibo-node1
```

### Step 4 — PolarFire 2: Bob uD3TN + A-SABR BDM

```bash
# T7 (PF2)
./ud3tn \
  -e dtn://bob.dtn/ \
  -S /tmp/bob.aap2.socket \
  -s /tmp/bob.socket \
  -c "csp:3,10,can0" \
  -d

# T8 (PF2)
source .venv/bin/activate
cd asabr_bdm
python main.py \
  ../demo/alice.cp \
  ../demo/bob-eid-map.json \
  --socket /tmp/bob.aap2.socket \
  -vv
```

### Step 5 — Charon on each side

```bash
# T9 (VM) — alice side
sudo ip netns exec alice_ns \
  env CHARON_SECRET=demo_secret \
  ./charon/build/charon demo/charon-alice.conf

# T10 (PF2) — bob side
 ip netns exec bob_ns \
  env CHARON_SECRET=demo_secret \
  ./charon demo/charon-bob.conf
```

---

## 6. Test

### Quick DTN chain test (no Charon)

Verify the multi-hop DTN path before involving Charon or apps.

```bash
# PF2 — receive on bob
python3 -m ud3tn_utils.aap2.bin.aap2_receive \
  --socket /tmp/bob.aap2.socket --agentid test -v -c 1

# VM — send from alice
echo "hello from PF experiment" | python3 -m ud3tn_utils.aap2.bin.aap2_send \
  --socket /tmp/alice.aap2.socket dtn://bob.dtn/test
```

### Full end-to-end test (with Charon)

```bash
# PF2 — App2 receiver (inside bob_ns)
 ip netns exec bob_ns ./apps/receiver 4000

# VM — App1 sender (inside alice_ns)
sudo ip netns exec alice_ns ./apps/sender 10.0.0.2 4000
```

Monitor CAN traffic on either board during the test:

```bash
candump can0     # all CSP frames (unibo↔hardy↔bob)
```

---

## 7. Troubleshooting

**TCPCLv3 connection refused (alice → unibo)**
Verify PF1's firewall allows TCP port 4225 from the VM's subnet, and that
`unibo-bp-tcpcl` is running and the induct was added.

**CSP frames on `can0` not reaching the other board**
Check CAN bitrate is identical (`ip -details link show can0`), termination
resistors are in place, and both interfaces are UP. Use `candump can0` on
both boards simultaneously.

**asabr_bdm not available on PolarFire**
If Python or the A-SABR module is not available on the board, run the BDM
on a companion x86 host that has network access to the board's AAP2 socket
via socat TCP forwarding:

```bash
# On PF2 — expose the AAP2 socket over TCP
socat TCP-LISTEN:9999,reuseaddr,fork UNIX-CONNECT:/tmp/bob.aap2.socket

# On the x86 host — connect the BDM to the forwarded socket
python main.py ../demo/alice.cp ../demo/bob-eid-map.json \
  --socket tcp://<PF2_IP>:9999 -vv
```

**Time drift between nodes**
A-SABR contact-plan routing is time-based. Large clock skews (>10 s) between
the VM and the PolarFire boards will cause incorrect routing decisions.
Synchronise clocks with NTP (`systemctl enable --now systemd-timesyncd`) or
GPS PPS before running the experiment.
