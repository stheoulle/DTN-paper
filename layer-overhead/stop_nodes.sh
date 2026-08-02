#!/usr/bin/env bash
pkill -f "build/posix/ud3tn -e dtn://node-a.dtn" 2>/dev/null || true
pkill -f "build/posix/ud3tn -e dtn://node-b.dtn" 2>/dev/null || true
rm -f /tmp/layer-node-a.aap2.socket /tmp/layer-node-a.socket
rm -f /tmp/layer-node-b.aap2.socket /tmp/layer-node-b.socket
echo "node-a and node-b stopped."
