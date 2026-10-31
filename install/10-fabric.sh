#!/usr/bin/env bash
# Generates the fabric configs and deploys the containerlab topology, which also creates the kind cluster and
# attaches each kind worker's eth1 to its leaf. Idempotent: a second run reconfigures instead of failing.
source "$(dirname "$0")/lib/common.sh"

step "fabric configs"
python3 "$REPO_ROOT/fabric/gen.py"

step "containerlab deploy ($CLAB_TOPO)"
cd "$REPO_ROOT/clab"
if docker ps --format '{{.Names}}' | grep -qx bnk-control-plane; then
  containerlab deploy -t "$CLAB_TOPO" --reconfigure
else
  containerlab deploy -t "$CLAB_TOPO"
fi

step "cluster"
kubectl get nodes -o wide
step "fabric sessions (leaf1)"
docker exec leaf1 vtysh -c 'show bgp summary' | sed -n '1,40p'
