#!/bin/bash
# Switches BNK from the Infra network model to the legacy one (needed for EVPN, see 10-network.yaml). Back to Infra:
# install/ai4/73-migrate.sh (the Infra CR and GatewaySettings stay in place and are ignored meanwhile).
#   1. legacy VLANs + F5BnkGateway (inert while USE_GATEWAY_SETTINGS=true)
#   2. every Gateway keeps its VIP: spec.addresses = its current address (R5 static NAT 10.10.12.3x -> 172.16.100.1x)
#   3. controller flag USE_GATEWAY_SETTINGS=false, Gateways re-pointed at F5BnkGateway
#   4. F5SPKStaticRoute (its validation webhook only works in legacy mode), routing re-applied, gate
set -euo pipefail
export KUBECONFIG=${BNK_KUBECONFIG:-$HOME/.kube/bnk-eve.config}
cd "$(dirname "$0")"
GW="demo/demo-gw lab-local/bnk-vip default/pool-vip default/lab-ai kagent/agents-gw apps/apps-gw"

echo "== 1. legacy network CRs"
python3 -c "import sys; print('\n---\n'.join(d for d in open('10-network.yaml').read().split('\n---\n') if 'F5SPKStaticRoute' not in d))" \
  | kubectl apply -f -

echo "== 2. pin Gateway addresses"
for g in $GW; do ns=${g%/*}; n=${g#*/}
  ip=$(kubectl -n "$ns" get gateway "$n" -o jsonpath='{.status.addresses[0].value}')
  kubectl -n "$ns" patch gateway "$n" --type merge -p "{\"spec\":{\"addresses\":[{\"type\":\"IPAddress\",\"value\":\"$ip\"}]}}" >/dev/null
  echo "  $g $ip"
done

echo "== 3. controller flag, Gateways to F5BnkGateway"
# Infra-only EgressGateways must go first: in legacy mode the controller panics on their VXLAN IPAM records
# (handleEgressVxlanIPAMSync -> getGWCrObjectFromStore, nil store) and restarts in a loop. Tenant egress comes back
# through the legacy F5SPKEgress (30-egress.yaml).
kubectl get egressgateways -A -o yaml > /tmp/egressgateways-backup.yaml
kubectl delete egressgateways -A --all --wait=false
kubectl -n default get ipam.fic.f5.com -o name | grep egressvxlan | xargs -r kubectl -n default delete --wait=false
kubectl -n default patch cneinstance bnk-eve --type merge -p '{"spec":{"advanced":{"cneController":{"env":[
  {"name":"TMM_DEFAUlT_MTU","value":"1500"},
  {"name":"USE_GATEWAY_SETTINGS","value":"false"},
  {"name":"MAX_ACTIVE_TMM_REPLICAS","value":"32"},
  {"name":"VRF_MODE","value":"true"}]}}}}'
for _ in $(seq 1 60); do
  kubectl -n default get deploy f5-cne-controller -o jsonpath='{.spec.template.spec.containers[0].env}' \
    | grep -q '"USE_GATEWAY_SETTINGS","value":"false"' && break
  sleep 5
done
kubectl -n default rollout status deploy/f5-cne-controller --timeout=300s
LEG='{"spec":{"infrastructure":{"parametersRef":{"group":"k8s.f5net.com","kind":"F5BnkGateway","name":"f5-bnkgateway"}}}}'
for g in $GW; do kubectl -n "${g%/*}" patch gateway "${g#*/}" --type merge -p "$LEG" >/dev/null; done

echo "== 4. static route, routing, gate"
python3 -c "print([d for d in open('10-network.yaml').read().split('\n---\n') if 'F5SPKStaticRoute' in d][0])" | kubectl apply -f -
../fabric/bnk/30-reapply-routing.sh
for g in $GW; do kubectl -n "${g%/*}" wait gateway/"${g#*/}" --for=condition=Programmed --timeout=180s >/dev/null || echo "  $g not Programmed"; done
kubectl get gateway -A
