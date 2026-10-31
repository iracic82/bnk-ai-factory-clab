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

apply_immutable() {   # $1 file: delete + recreate the routing CRs in it if the content changed
  local f="$1" h; h=$(sha256sum "$f" | cut -c1-16)
  local cur; cur=$(kubectl -n f5-bnk get routingtemplates.k8s.f5net.com,globalroutingconfigs.k8s.f5net.com,routingconfigs.k8s.f5net.com \
                   -o jsonpath='{range .items[*]}{.metadata.annotations.factory\.lab/hash}{" "}{end}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$' || true)
  if [ -n "$cur" ] && [ "$cur" != "$h" ]; then
    warn "routing CRs changed; deleting the old ones (immutable upstream)"
    kubectl -n f5-bnk delete routingconfigs.k8s.f5net.com,globalroutingconfigs.k8s.f5net.com,routingtemplates.k8s.f5net.com --all --wait >/dev/null
  fi
  kubectl apply -f "$f" >/dev/null
  for k in routingtemplates.k8s.f5net.com globalroutingconfigs.k8s.f5net.com routingconfigs.k8s.f5net.com; do
    kubectl -n f5-bnk annotate "$k" --all "factory.lab/hash=$h" --overwrite >/dev/null 2>&1 || true
  done
}

step "tenant namespaces and hello apps"
kubectl apply -f "$M/tenants/hello.yaml" >/dev/null
step "TMM legs and VIP pool"
# the internal leg lives on the kind docker network, whose subnet docker chooses per host
KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Subnet}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/' | head -1)
[ -n "$KIND_SUBNET" ] || fail "cannot read the kind network subnet"
INTERNAL_SELFIP="$(echo "${KIND_SUBNET%/*}" | cut -d. -f1-3).250"; INTERNAL_PLEN="${KIND_SUBNET#*/}"
sed -e "s|__INTERNAL_SELFIP__|$INTERNAL_SELFIP|" -e "s|__INTERNAL_PLEN__|$INTERNAL_PLEN|" "$M/bnk/10-network.yaml" | kubectl apply -f -
ok "internal self IP $INTERNAL_SELFIP/$INTERNAL_PLEN on the kind network $KIND_SUBNET"
step "global routing"
apply_immutable "$M/bnk/20-routing-global.yaml"
step "tenant VRFs, routing, first VIPs"
kubectl apply -f "$M/bnk/40-tenants.yaml"
apply_immutable "$M/bnk/40-tenants.yaml"
step "tenant egress"
kubectl apply -f "$M/bnk/30-egress.yaml"

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
