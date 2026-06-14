# A-SABR

```bash
git clone --depth 1 --recursive https://gitlab.com/d3tn/ud3tn.git
```

```bash
uv python install 3.13
uv venv --python 3.13
source .venv/bin/activate
```

```bash
git clone https://github.com/theotchlx/A-SABR-Python.git
cd A-SABR-Python
git checkout feat/asabr-bdm
maturin develop
cd ..
```

```bash
git clone --depth 1 https://github.com/theotchlx/asabr_bdm.git
```

**Install the python dependencies defined in pyproject.toml into your venv**, then plug our BDM to Node 0:

```bash
cd asabr_bdm
uv sync --active
cd ..
#python main.py ../test.cp ../test.json --socket ../ud3tn/ud3tn.aap2.socket -vv
```

# Libcsp

```bash
git clone https://github.com/libcsp/libcsp.git
cd libcsp
git checkout v1.6
python3.11 waf configure --enable-can-socketcan --enable-if-zmqhub --enable-rdp
python3.11 waf build
cd ..
```

# CSPCL build from source

```bash
git clone https://github.com/dtn-mtp/cspcl.git
cd cspcl
git checkout feat/improve-rust-bindings
mkdir build && cd build
cmake -DCSP_REPO_DIR=../../libcsp/ .. && make
cd ../..

export CSPCL_REPO=$(pwd)/cspcl
export UD3TN_REPO=$(pwd)/ud3tn

# Fix hardcoded paths in the patch before applying
sed -i "s|/home/mathias/libcsp-src|$(pwd)/libcsp|g" ${CSPCL_REPO}/ud3tn-integration/dev.patch

# Apply the CSPCL integration patch (only on a fresh ud3tn clone)
cd ${UD3TN_REPO}
git apply ${CSPCL_REPO}/ud3tn-integration/dev.patch

# Copy CSPCL library files
mkdir -p external/cspcl
cp ${CSPCL_REPO}/src/cspcl.c external/cspcl/
cp ${CSPCL_REPO}/src/cspcl.h external/cspcl/
cp ${CSPCL_REPO}/src/cspcl_config.h external/cspcl/


# Copy CLA_CSP integration files
cp ${CSPCL_REPO}/ud3tn-integration/src/cla_csp.c components/cla/posix/
cp ${CSPCL_REPO}/ud3tn-integration/src/cla_csp.h include/cla/

# Build
make posix
cd ..
```

# Unibo

```bash
mkdir unibo-dtn
cd unibo-dtn
git clone https://gitlab.com/unibo-dtn/unibo-cgr.git
git clone --recursive https://gitlab.com/unibo-dtn/unibo-bp.git
cd unibo-bp
make init WITH_QUICCL=1
make
sudo make install
sudo ldconfig

cd ../..
export UNIBO_BP_BIN=$(pwd)/unibo-dtn/unibo-bp/build/Unibo-BP/bin
export UNIBO_BP_LIB=$(pwd)/unibo-dtn/unibo-bp/build/Unibo-BP/lib
export LIBCSP_BUILD=$(pwd)/libcsp/build

cd cspcl/unibo-integration && mkdir -p build
sudo apt install libzmq3-dev
gcc -O2 -Wall -Wextra \
  src/cspcl_daemon.c ../src/cspcl.c \
  -o build/unibo-bp-cspcl \
  -I../src \
  -I../../unibo-dtn/unibo-bp/include \
  -I../../libcsp/include \
  -I../../libcsp/build/include \
  -L$UNIBO_BP_LIB -Wl,-rpath,$UNIBO_BP_LIB \
  -lunibo-bp-api $LIBCSP_BUILD/libcsp.a \
  -lsocketcan -lpthread -lm \
  -lzmq
cd ../..
```

# Hardy

```bash
git clone -b feat/cspcl-v2 https://github.com/hugoponthieu/hardy.git 
cd hardy
git checkout feat/rdp
# CSP_REPO_DIR and CSP_BUILD_DIR must point at the built libcsp:
export CSP_REPO_DIR=$(pwd)/../libcsp
export CSP_BUILD_DIR=$(pwd)/../libcsp/build
sudo apt install clang libbz2-dev
cargo build --release -p hardy-bpa-server --features cspcl
cd ..
```

# Charon

```bash
# Dependencies: protobuf-c-compiler libprotobuf-c-dev
git clone https://github.com/DTN-MTP/charon.git
cd charon
make proto   # regenerates src/proto/aap2.pb-c.{c,h} from proto/aap2.proto
mkdir build
make
cd ..
# binary: build/charon
```

# Apply patches

After all repos are cloned, apply the DTN-paper patches in one step from the repo root:

```bash
bash patches/apply.sh
```

This patches charon, cspcl, hardy, and ud3tn in place. The script must be run **before** building any of those components.

What each patch does:

| Repo | Changes |
|------|---------|
| `charon` | Configurable TUN name, `/30` prefix, IPv6 disable, IPv4-only filter, ACK wait in `send_aap2` |
| `cspcl` | Separate RDP connect timeout (100 ms), always-invalidate connection pool after send |
| `hardy` | `eid_map` / `reverse_eid_map` so A-SABR can route to `dtn://` EIDs, not just IPN |
| `ud3tn` | CSP CLA registration, libcsp include/link paths, new `cla_csp` and `cspcl` source files |
