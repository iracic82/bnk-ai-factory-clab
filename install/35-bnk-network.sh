#!/usr/bin/env bash
# TMM on the fabric: its legs, the VIP pool, BGP to leaf1 in the default route domain and in every tenant VRF, the
# tenant VRFs with a first VIP each, and per-tenant egress. Then proves it from the client behind r5.
#
# Order matters: VLANs before routing (the self IPs are what BGP sources from), templates before the configs that
# reference them, VRFs before the VIPs in them. Routing templates and configs are immutable: a change means delete and
# recreate, which this script does when the file content differs from what is applied (annotation with a hash).
source "$(dirname "$0")/lib/common.sh"
M="$REPO_ROOT/manifests"
kubectl -n f5-bnk get cneinstance f5-bnk-instance >/dev/null || fail "no CNEInstance; run 30-bnk.sh"

# Every F5 CR goes through the f5-validation webhook. The webhook pod restarts with the rest of the stack whenever
# the CNEInstance changes (30-bnk.sh patches it last thing), and the API server then answers "connection refused"
# for every F5 object until the pod listens again. So: wait for a ready endpoint, and retry the apply itself.
wait_webhook() {
  for _ in $(seq 1 60); do
    [ -n "$(kubectl -n f5-bnk get endpoints f5-validation-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ] && return 0
    sleep 5
  done
  warn "f5-validation-svc has no ready endpoint after 5 min"
}
apply_f5() {          # kubectl apply -f "$1" (or - for stdin held in $2), retried while the webhook is unreachable
  local f="$1" body="${2:-}" out
  wait_webhook
  for i in $(seq 1 12); do
    if [ -n "$body" ]; then out=$(printf '%s' "$body" | kubectl apply -f - 2>&1); else out=$(kubectl apply -f "$f" 2>&1); fi
    echo "$out" | grep -v 'failed calling webhook' || true
    echo "$out" | grep -q 'failed calling webhook' || return 0
    [ "$i" -lt 12 ] && sleep 10
  done
  fail "the F5 validation webhook kept refusing $f"
}

apply_immutable() {   # $1 file: apply it; the routing CRs *in this file* are deleted first if the file changed
  # Each file carries its own hash, and only the routing objects named in that file are compared and deleted.
  # (The first version compared one hash across every routing CR, so applying 40-tenants.yaml after
  # 20-routing-global.yaml deleted the GlobalRoutingConfig: bake of 2026-10-31.)
  local f="$1" h; h=$(sha256sum "$f" | cut -c1-16)
  local objs; objs=$(kubectl -n f5-bnk apply --dry-run=client -o name -f "$f" | grep -E '^(routingtemplate|globalroutingconfig|routingconfig)\.' || true)
  local stale="" o cur
  for o in $objs; do
    cur=$(kubectl -n f5-bnk get "$o" -o jsonpath='{.metadata.annotations.factory\.lab/hash}' 2>/dev/null || true)
    [ -n "$cur" ] && [ "$cur" != "$h" ] && stale="$stale $o"
  done
  if [ -n "$stale" ]; then
    warn "$(basename "$f") changed; recreating its routing CRs (immutable upstream):$stale"
    kubectl -n f5-bnk delete $stale --wait >/dev/null
  fi
  apply_f5 "$f"
  for o in $objs; do kubectl -n f5-bnk annotate "$o" "factory.lab/hash=$h" --overwrite >/dev/null 2>&1 || true; done
}

# Routing first: 30-bnk.sh switched dynamicRouting on, so TMM is restarting and its init-f5-tmm-routing container is
# waiting for exactly these objects. Everything else can follow while TMM comes back.
step "global routing (TMM's routing init waits for this)"
apply_immutable "$M/bnk/20-routing-global.yaml"
step "tenant namespaces and hello apps"
kubectl apply -f "$M/tenants/hello.yaml" >/dev/null
step "TMM legs and VIP pool"
# the internal leg lives on the kind docker network, whose subnet docker chooses per host
KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Subnet}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/' | head -1)
[ -n "$KIND_SUBNET" ] || fail "cannot read the kind network subnet"
INTERNAL_SELFIP="$(echo "${KIND_SUBNET%/*}" | cut -d. -f1-3).250"; INTERNAL_PLEN="${KIND_SUBNET#*/}"
apply_f5 "$M/bnk/10-network.yaml" "$(sed -e "s|__INTERNAL_SELFIP__|$INTERNAL_SELFIP|" -e "s|__INTERNAL_PLEN__|$INTERNAL_PLEN|" "$M/bnk/10-network.yaml")"
ok "internal self IP $INTERNAL_SELFIP/$INTERNAL_PLEN on the kind network $KIND_SUBNET"

step "routes to the shared VIP pool through TMM's internal leg (nodes and the VM)"
# Published VIPs (172.16.100.0/24: pool VIP, AI Gateway routes, agents gateway) are announced to the fabric, which
# the client behind r5 uses. Pods and the VM have no leg on the fabric; they reach the same VIPs through TMM's
# internal self IP on the kind network, the way the EVE lab's nodes reached them through R5's address on the node
# subnet. Tenant pods are different: F5SPKEgress steers them into their VRF, and the fabric brings them back.
for n in bnk-control-plane bnk-worker bnk-worker2; do docker exec "$n" ip route replace 172.16.100.0/24 via "$INTERNAL_SELFIP"; done
sudo ip route replace 172.16.100.0/24 via "$INTERNAL_SELFIP" 2>/dev/null || warn "could not add the VM route to 172.16.100.0/24"
# Calico masquerades pod traffic leaving a node. That must not apply to traffic entering the node -> TMM egress
# tunnels (CSRC's bnkvxlan* interfaces), or TMM sees the node's address instead of the pod's and the F5SPKEgress
# SNAT never matches. The EVE lab set the same filter for its node NIC (install/ai4/75-calico-node-egress.sh there).
kubectl patch felixconfigurations.crd.projectcalico.org default --type merge -p '{"spec":{"iptablesNATOutgoingInterfaceFilter":"eth0"}}' >/dev/null
ok "VIP routes via $INTERNAL_SELFIP on 3 nodes and the VM; Calico NAT-outgoing limited to eth0"
step "TMM back with routing"
kubectl -n f5-bnk rollout status ds/f5-tmm --timeout="$(tmo 900s 600s)" >/dev/null 2>&1 || kubectl -n f5-bnk wait --for=condition=Ready pod -l app=f5-tmm --timeout="$(tmo 600s 300s)" >/dev/null 2>&1 || {
  warn "TMM not Ready yet:"; kubectl -n f5-bnk get pods -l app=f5-tmm -o wide | sed 's/^/      /'
  kubectl -n f5-bnk get pods -l app=f5-tmm -o jsonpath='{range .items[*].status.initContainerStatuses[*]}{.name}={.state}{"\n"}{end}{range .items[*].status.containerStatuses[*]}{.name}={.state}{"\n"}{end}' | sed 's/^/      /'; }
step "tenant VRFs, routing, first VIPs"
apply_immutable "$M/bnk/40-tenants.yaml"
step "tenant egress"
apply_f5 "$M/bnk/30-egress.yaml"

step "BGP from TMM, as leaf1 sees it"
for i in $(seq 1 60); do
  n=$(docker exec leaf1 vtysh -c 'show bgp vrf all summary json' 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin); n=0
for vrf,fam in d.items():
    for af,v in fam.items():
        for p,s in (v.get('peers') or {}).items():
            if s.get('state')=='Established' and str(s.get('remoteAs'))=='65100': n+=1
print(n)" 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 4 ] && break; sleep 10
done
docker exec leaf1 vtysh -c 'show bgp vrf all summary' | grep -E 'VRF|65100'
[ "${n:-0}" -ge 4 ] && ok "TMM peers with leaf1 in the default domain and in 3 tenant VRFs" || warn "only $n TMM sessions Established"

step "VIPs from the client (through r5, border1, EVPN, leaf1, TMM)"
for t in a b c; do
  vip="10.20$(printf '%d' "$(( $(printf '%d' "'$t") - 96 ))").100.10"
  printf '  tenant-%s %-16s ' "$t" "$vip"
  docker exec client curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$vip/" || echo "no answer"
done
