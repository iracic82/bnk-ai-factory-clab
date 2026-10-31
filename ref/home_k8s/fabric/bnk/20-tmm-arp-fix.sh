#!/bin/bash
# TMM db key arp.verifyreturnroute = disable, through the operator-generated ConfigMap tmm-init (user_conf.tcl, which
# TMM re-reads every second). Idempotent; re-run after anything that re-renders tmm-init (CNEInstance changes).
#
# Why (found 2026-10-28 on BNK 2.4.1 with OcNOS routing): TMM's internal leg sits on the node subnet (10.10.12.0/24,
# self IPs .41-.43). A node ARPs for its local TMM pod (eth0, pod IP) from its node IP. With the BIG-IP default
# arp.verifyreturnroute = enable, TMM drops that request: the return route to the sender leaves through another VLAN
# (internal), not the one the request came in on. Once the node's ARP entry ages out the TMM pod IP is unreachable, the
# controller loses its gRPC channels to that TMM (config push fails, self-IP allocation gets out of step).
# There is no CNEInstance/F5Tmm field for TMM db keys, hence the ConfigMap patch.
set -eu
export KUBECONFIG=${BNK_KUBECONFIG:-$HOME/.kube/bnk-eve.config}
cur=$(kubectl -n default get cm tmm-init -o jsonpath='{.data.user_conf\.tcl}')
if grep -q 'arp.verifyreturnroute disable' <<<"$cur"; then echo "tmm-init: already set"; exit 0; fi
new=$(printf '\n\t\tbigdb arp.verifyreturnroute disable\n%s' "$cur")
kubectl -n default patch cm tmm-init --type merge \
  -p "$(python3 -c 'import json,sys; print(json.dumps({"data": {"user_conf.tcl": sys.argv[1]}}))' "$new")"
echo "tmm-init: arp.verifyreturnroute disable added (TMM picks it up within ~1 min, no restart)"
