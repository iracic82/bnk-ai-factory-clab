#!/bin/bash
# Rebuilds the tenant objects in dependency order. Needed after a TMM restart when a fresh TMM stays not Ready and the
# controller logs "grpcRetryHandler: Error while sending message to <TMM pod IP>: [gRPC config errno: 15]": the old Vrf
# CRs fail to re-push (TMM ERR_NOT_FOUND) and block everything that depends on them (docs/fabric-evpn.md, step 3).
# Down: routing, tenant egress, virtual servers, Vxlans, VRF-bound VLANs, Vrfs. Up in reverse, then the routing script.
# The controller restarts now and then on RoutingConfig deletes, so every delete waits for it and retries.
set -u
export KUBECONFIG=${BNK_KUBECONFIG:-$HOME/.kube/bnk-eve.config}
cd "$(dirname "$0")/../../.."
T=install/legacy/40-tenants-evpn.yaml
ctrl() { kubectl -n default rollout status deploy/f5-cne-controller --timeout=300s >/dev/null; sleep 10; }
ts() { echo "$(date +%T) $*"; }
del() { for _ in 1 2 3; do ctrl; kubectl -n default delete "$@" --ignore-not-found --wait=true --timeout=120s >/dev/null && return; done; }
kind() { python3 -c '
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
print("\n---\n".join(d for d in docs if "\nkind: "+sys.argv[2]+"\n" in "\n"+d+"\n"))' $T "$1"; }

ts "down"
for t in tenant-a tenant-b tenant-c; do del routingconfigs.k8s.f5net.com $t; done
del globalroutingconfig global-config
del f5-spk-egresses.k8s.f5net.com tenant-a-egress tenant-b-egress tenant-c-egress
del f5-spk-snatpools.k8s.f5net.com tenant-a-snat tenant-b-snat tenant-c-snat
for v in tenant-a-vip tenant-b-vip tenant-c-vip; do del f5-virtualservers.k8s.f5net.com $v; done
for x in vni10001 vni10002; do del vxlans.k8s.f5net.com $x; done
del f5-spk-vlans.k8s.f5net.com fab-a fab-b fab-c
for v in tenant-a tenant-b tenant-c; do del vrfs.k8s.f5net.com $v; done
for _ in $(seq 1 24); do
  [ -z "$(kubectl -n default get cm secure-spk-tmmcnfmappings-default -o jsonpath='{.data.vxlanInfo}' | python3 -c 'import sys,json; print(" ".join(v["name"] for v in json.load(sys.stdin)["pseudocni-vxlan-config"] if v["tmmassignedifaces"]))')" ] && break
  sleep 5
done
sleep 20

ts "up"
ctrl; kind Vrf | kubectl apply -f - >/dev/null; sleep 20
ctrl; kubectl apply -f install/legacy/10-network.yaml >/dev/null; sleep 20
ctrl; kind Vxlan | kubectl apply -f - >/dev/null; sleep 30
ctrl; kind F5VirtualServer | kubectl apply -f - >/dev/null; sleep 20
ctrl; bash install/fabric/bnk/30-reapply-routing.sh || exit 1
ctrl; kubectl apply -f install/legacy/30-egress.yaml >/dev/null; sleep 20
kubectl -n default get vrfs.k8s.f5net.com,vxlans.k8s.f5net.com,f5-spk-vlans.k8s.f5net.com,f5-spk-egresses.k8s.f5net.com,routingconfigs.k8s.f5net.com,globalroutingconfig --no-headers | awk '{print $1, $2}'
kubectl -n default get pod -l app=f5-tmm --no-headers
# CSRC leaves the deleted egress tunnels on the nodes; drop every vxlan10x no policy rule uses any more:
#   for n in nodes: for l in $(ip -br link show type vxlan): ip rule | grep -q $l || ip link del $l
ts "done"
