# This README is here to guide you to run the demo for the paper 'CSPCL: A Stepwise, Non-Disruptive Transition to Delay-Tolerant Networking for CubeSat Operators''

# Setup

## Step 1 — Clone everything

```bash
# uD3TN (Node 0 / Node 3 BPA)
git clone --depth 1 --recursive https://gitlab.com/d3tn/ud3tn.git

# A-SABR routing library and BDM
git clone https://github.com/theotchlx/A-SABR-Python.git
git clone --depth 1 https://github.com/theotchlx/asabr_bdm.git

# CSP library
git clone https://github.com/libcsp/libcsp.git

# CSPCL (CSP-over-CAN bundle adapter)
git clone https://github.com/dtn-mtp/cspcl.git

# Unibo BP (Node 1 BPA)
mkdir unibo-dtn && cd unibo-dtn
git clone https://gitlab.com/unibo-dtn/unibo-cgr.git
git clone --recursive https://gitlab.com/unibo-dtn/unibo-bp.git
cd ..

# Hardy (Node 2 BPA)
git clone -b feat/cspcl-v2 https://github.com/hugoponthieu/hardy.git

# Charon (IP-over-DTN tunnel)
git clone https://github.com/DTN-MTP/charon.git
```

## Step 2 — Python environment

```bash
uv python install 3.13
uv venv --python 3.13
source .venv/bin/activate

cd A-SABR-Python
git checkout feat/asabr-bdm
maturin develop
cd ..

cd asabr_bdm
uv sync --active
cd ..
```

## Step 3 — Apply patches

```bash
bash patches/apply.sh
```

This must be run **before** building any component. It patches charon, cspcl, hardy, and ud3tn in place.

| Repo | Changes |
|------|---------|
| `charon` | Configurable TUN name, `/30` prefix, IPv6 disable, IPv4-only filter, ACK wait in `send_aap2` |
| `cspcl` | Separate RDP connect timeout (100 ms), always-invalidate connection pool after send |
| `hardy` | `eid_map` / `reverse_eid_map` so A-SABR can route to `dtn://` EIDs, not just IPN |
| `ud3tn` | CSP CLA registration, libcsp include/link paths, new `cla_csp` and `cspcl` source files |

## Step 4 — Build (in dependency order)

### libcsp

```bash
cd libcsp
git checkout v1.6
python3.11 waf configure --enable-can-socketcan --enable-if-zmqhub --enable-rdp
python3.11 waf build
cd ..
```

### cspcl

```bash
cd cspcl
git checkout feat/improve-rust-bindings
mkdir build && cd build
cmake -DCSP_REPO_DIR=../../libcsp/ .. && make
cd ../..
```

### unibo-bp

```bash
cd unibo-dtn/unibo-bp
make init WITH_QUICCL=1
make
sudo make install
sudo ldconfig
cd ../..
```

### hardy

```bash
cd hardy
git checkout feat/rdp
sudo pacman -S clang bzip2
CSP_REPO_DIR=$(pwd)/../libcsp CSP_BUILD_DIR=$(pwd)/../libcsp/build \
  cargo build --release -p hardy-bpa-server --features cspcl
cd ..
```

### ud3tn

```bash
cd ud3tn
make posix
cd ..
```

### charon

```bash
# Dependencies: protobuf-c-compiler libprotobuf-c-dev
cd charon
make proto
mkdir -p build
make
cd ..
# binary: build/charon
```
