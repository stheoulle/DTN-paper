# A-SABR

```bash
git clone --depth 1 --recursive https://gitlab.com/d3tn/ud3tn.git
cd ud3tn
# ...install dependencies on your system...
make posix
cd ..
```

```bash
uv python install 3.13
uv venv --python 3.13
source .venv/bin/activate
```

```bash
git clone https://github.com/theotchlx/A-SABR-Python.git
git checkout feat/asabr-bdm
cd A-SABR-Python
maturin develop
```

```bash
git clone --depth 1 https://github.com/theotchlx/asabr_bdm.git
```

Create a contact plan `test.cp`:

```json
# Node entry with no management: node <id> <name>
node 0 node0
node 1 node1
node 2 node2
node 3 node3
node 4 node4
node 5 node5

# Contact entry with a legacy approach: contact <from> <to> <start> <end> <rate> <delay>
contact 0 1 0 9999999999 10000 10
contact 1 2 0 9999999999 15000 15
contact 2 3 0 9999999999 20000 20
contact 3 4 0 9999999999 25000 25
contact 4 5 0 9999999999 30000 30
```

And a corresponding EID/CLA <-> node ID map in JSON :
Because we will launch only 2 BPAs (Nodes 0 and 1) and plug our BDM to Node 0, we are only interested in the contacts between Nodes 0 and 1. So we don't need to specify the other CLAs.

`test.json`

```json
{
    "dtn://node1.dtn/": {"name": "node1", "cla_addr": null},
    "dtn://node2.dtn/": {"name": "node2", "cla_addr": "mtcp:127.0.0.1:4225"},
    "dtn://node3.dtn/": {"name": "node3", "cla_addr": null},
    "dtn://node4.dtn/": {"name": "node4", "cla_addr": null},
    "dtn://node5.dtn/": {"name": "node5", "cla_addr": null},
    "dtn://node6.dtn/": {"name": "node6", "cla_addr": null}
}
```

Still from the demo directory, you will need four terminals : two for running and logging the uD3TN instances of Nodes 0 and 1, one to manually send a bundle, and one to plug our BDM dispatcher to Node 0.

Launch the two BPAs :

Node 0 :

```bash
cd ud3tn
./build/posix/ud3tn \
          -e dtn://node1.dtn/ \
          -S ./ud3tn.aap2.socket \
          -s ./ud3tn.socket \
          -d # for using the BDM.
```

Node 1 :

```bash
cd ud3tn
./build/posix/ud3tn \
          -e dtn://node2.dtn/ \
          -S ./ud3tn2.aap2.socket \
          -s ./ud3tn2.socket \
          -c "mtcp:*,4225"
```

**Install the python dependencies defined in pyproject.toml into your venv**, then plug our BDM to Node 0:

```bash
cd asabr_bdm
uv sync --active
python main.py ../test.cp ../test.json --socket ../ud3tn/ud3tn.aap2.socket -vv
```

You should see the CLA connection establishment between Node 0 and Node 1, as the BDM registers the contact specified in the CP and EID/CLA map.

Send a bundle from Node 0 to Node 5:

```bash
cd ud3tn
python python-ud3tn-utils/ud3tn_utils/aap2/bin/aap2_send.py --socket ud3tn.aap2.socket dtn://node5.dtn "hello from node0"
```

The BDM should display that the next hop is to Node 1.
Since there is currently a viable contact and CLA connection, the bundle gets forwarded.
It should also display the dispatch reason:

| Name | Number | Description |
|------|--------|-------------|
| DISPATCH_REASON_UNSPECIFIED | 0 | Invalid. |
| DISPATCH_REASON_NO_FIB_ENTRY | 1 | No direct-dispatch link was found for the destination EID in the FIB. |
| DISPATCH_REASON_LINK_INACTIVE | 2 | The link that should be used is currently not active or unusable. |
| DISPATCH_REASON_CLA_ENQUEUE_FAILED | 3 | The CLA subsystem responded negatively to the next-hop TX request or no applicable CLA and link could be determined for the given fragment. |
| DISPATCH_REASON_TX_FAILED | 4 | The transmission was attempted by the CLA, but failed. |
| DISPATCH_REASON_TX_SUCCEEDED | 5 | The CLA transmission succeeded (this is an information to the BDM). Note that this may concern the whole bundle (if determined to be sent completely), or just a single fragment. |
