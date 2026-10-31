#!/bin/bash
# Re-applies the GlobalRoutingConfig + RoutingTemplate (10-routing-global.yaml) once every TMM pod is Ready.
# Needed after a change to the routing template. (In legacy mode new TMM pods get the routing config on their own.) Routing CRs are immutable, so delete + apply. If it is not Programmed within a
# minute, the committed version (git HEAD) goes back in. Deleting the GlobalRoutingConfig also deletes every
# RoutingConfig (F5 "Configure tenant BGP routing"), so the tenant overlay (install/legacy/40-tenants-evpn.yaml) is
# applied again afterwards.
# The template's vtep-ip-global per DP slot comes from the controller's Vxlan allocation. All tenant Vxlans (the
# tenants TMM terminates as VTEP; tenant-c behind the DPUs has none) share one
# VTEP per TMM, so their slot maps must agree; a Vxlan created later (another pod order) can get the map reversed and
# its tunnel then sources from the other TMM's VTEP. If they disagree, all Vxlans are recreated in one pass.
set -eu
export KUBECONFIG=${BNK_KUBECONFIG:-$HOME/.kube/bnk-eve.config}
cd "$(dirname "$0")"
G=10-routing-global.yaml
T=../../legacy/40-tenants-evpn.yaml
R=$(mktemp); trap 'rm -f $R' EXIT

# prints "<vni> DP-0=a DP-1=b" per tenant Vxlan from the controller's state
slotmaps() {
  kubectl -n default get cm secure-spk-tmmcnfmappings-default -o jsonpath='{.data.vxlanInfo}' | python3 -c '
import sys, json
for v in json.load(sys.stdin)["pseudocni-vxlan-config"]:
    if v["tmmassignedifaces"]:  # a deleted Vxlan can stay behind with no TMMs
        print(v["name"], " ".join(sorted(t["tmmName"] + "=" + t["localIp"] for t in v["tmmassignedifaces"])))'
}

# renders the template on stdin with the slot map in $1
render() {
  python3 -c '
import sys
s = sys.stdin.read()
for kv in sys.argv[1].split():
    dp, ip = kv.split("=")
    s = s.replace(f"__VTEP_{dp}__", ip)
print("\n".join(l for l in s.split("\n") if "__VTEP_" not in l))' "$1"
}

# TMM containers up. Not pod Ready: its readiness gates (RoutingDone, ConfigurationDone, set by f5-tmm-pod-manager)
# can wait for the routing config this script pushes
tmm_up() { kubectl -n default wait pod -l app=f5-tmm --for=condition=ContainersReady --timeout=600s >/dev/null; }

# the controller also serves the validating webhook; deleting the GlobalRoutingConfig while RoutingConfigs still
# reference it crash-loops it, so delete in dependency order and wait for it in between
ctrl() { kubectl -n default rollout status deploy/f5-cne-controller --timeout=300s >/dev/null; sleep 5; }

# the controller panics now and then on a RoutingConfig delete (slice bounds out of range) and restarts with its
# webhook; one at a time, waiting for it and retrying, gets every delete through
delrc() {
  for _ in 1 2 3 4 5 6; do
    ctrl
    rc=$(kubectl -n default get routingconfigs.k8s.f5net.com -o name 2>/dev/null | head -1)
    [ -z "$rc" ] && return 0
    kubectl -n default delete "$rc" --wait=true --timeout=60s >/dev/null 2>&1 || true
  done
  [ -z "$(kubectl -n default get routingconfigs.k8s.f5net.com -o name 2>/dev/null)" ]
}

realloc() {
  echo "tenant Vxlan slot maps disagree, recreating all Vxlans in one pass" >&2
  delrc
  ctrl; kubectl delete -f $G --ignore-not-found >/dev/null
  ctrl; kubectl -n default delete vxlans.k8s.f5net.com --all --wait=true >/dev/null
  for _ in $(seq 1 24); do [ -z "$(slotmaps)" ] && break; sleep 5; done
  python3 -c '
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
print("\n---\n".join(d for d in docs if "\nkind: Vxlan\n" in "\n" + d + "\n"))' $T | kubectl apply -f - >/dev/null
  for _ in $(seq 1 24); do [ "$(slotmaps | wc -l)" -ge "$(grep -c '^kind: Vxlan$' $T)" ] && break; sleep 5; done
}

reapply() {
  tmm_up
  # right after a TMM restart the maps disagree for a while as the new pods register; only a lasting split is real
  for _ in $(seq 1 12); do [ "$(slotmaps | cut -d' ' -f2- | sort -u | wc -l)" = 1 ] && break; sleep 5; done
  [ "$(slotmaps | cut -d' ' -f2- | sort -u | wc -l)" = 1 ] || { realloc; REALLOC=1; }
  [ "$(slotmaps | cut -d' ' -f2- | sort -u | wc -l)" = 1 ] || { echo "slot maps still disagree:" >&2; slotmaps >&2; exit 1; }
  map=$(slotmaps | head -1 | cut -d' ' -f2-)
  render "$map" <$G >$R
  delrc
  ctrl; kubectl delete -f $R --ignore-not-found >/dev/null
  sleep 3
  kubectl apply -f $R >/dev/null
  for _ in $(seq 1 10); do
    sleep 6
    s=$(kubectl -n default get globalroutingconfig global-config -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
    [ "$s" = True ] && { echo "VTEPs: $map"; return 0; }
  done
  echo "not Programmed, rolling back to git HEAD" >&2
  kubectl delete -f $R >/dev/null
  git show HEAD:install/fabric/bnk/$G | render "$map" | kubectl apply -f - >/dev/null
  exit 1
}

REALLOC=0
reapply
kubectl apply -f $T >/dev/null
# OcNOS on a running TMM: "After map/unmap of L3VNI from VRF ... System Reboot required", so a recreated Vxlan only
# takes effect in fresh TMM pods (they get the slot map back from the controller's state)
if [ $REALLOC = 1 ]; then
  # a fresh TMM that gets a tenant RoutingConfig before the global one keeps its VRF without RD ("Malformed ecommunity
  # value", then every RT is rejected) for the pod's lifetime, and OcNOS takes no manual config. So the pods restart
  # with no tenant RoutingConfigs; the controller's Vrf CRs alone create the bare VRFs, the RDs come after the global
  sleep 20
  delrc
  ctrl; kubectl -n default delete pod -l app=f5-tmm --wait=true >/dev/null
  sleep 30
  tmm_up
  echo "TMM pods restarted for the new L3VNI mapping"
  sleep 30
  reapply
  kubectl apply -f $T >/dev/null
fi
# each TMM must hold an rd and a BGP address-family per tenant RoutingConfig
want=$(grep -c '^kind: RoutingConfig$' $T)
for _ in $(seq 1 20); do
  bad=0
  for p in $(kubectl -n default get pod -l app=f5-tmm -o name); do
    c=$(kubectl -n default exec $p -c f5-tmm-routing -- imish -e 'show running-config' 2>/dev/null || true)
    [ "$(grep -c '^ rd ' <<<"$c")" = "$want" ] && [ "$(grep -c 'address-family ipv4 vrf' <<<"$c")" = "$want" ] || bad=1
  done
  [ $bad = 0 ] && break
  sleep 6
done
[ $bad = 0 ] || { echo "a TMM is missing tenant routing, see /tmp/last_commit_error.txt in its f5-tmm-routing container" >&2; exit 1; }
echo "GlobalRoutingConfig programmed on $(kubectl -n default get pod -l app=f5-tmm --no-headers | wc -l) TMM(s), tenant RoutingConfigs re-applied"
