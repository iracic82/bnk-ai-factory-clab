#!/bin/bash
# BNK 2.4.1: cut over from the legacy network model (F5SPKVlan + F5BnkGateway) to Infra + GatewaySettings.
# Run on bnk-cp1 as root. Rollback: 74-rollback.sh. Legacy CRs are left in place; with
# USE_GATEWAY_SETTINGS=true the controller ignores them, so they are the rollback path.
#   phase 1 (inert, no traffic impact): Infra + GatewaySettings are applied while the controller still ignores them
#   phase 2 (change window): controller env USE_GATEWAY_SETTINGS=true, Gateways repointed, wait for Programmed
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
cd "$(dirname "$0")"
GW="demo/demo-gw lab-local/bnk-vip default/pool-vip default/lab-ai kagent/agents-gw"

echo "== phase 1: pre-stage"
kubectl apply -f 70-infra-egress.yaml -f 72-ingress-gatewaysettings.yaml

echo "== phase 2: controller flag"
kubectl patch cneinstance bnk-eve -n default --type merge -p '{"spec":{"advanced":{"cneController":{"env":[
  {"name":"TMM_DEFAUlT_MTU","value":"1500"},
  {"name":"USE_GATEWAY_SETTINGS","value":"true"},
  {"name":"MAX_ACTIVE_TMM_REPLICAS","value":"32"}]}}}}'
for i in $(seq 1 60); do
  kubectl -n default get deploy f5-cne-controller -o jsonpath='{.spec.template.spec.containers[0].env}' | grep -q USE_GATEWAY_SETTINGS && break; sleep 5
done
kubectl -n default rollout status deploy/f5-cne-controller --timeout=300s

echo "== phase 2: repoint Gateways"
for g in $GW; do ns=${g%/*}; n=${g#*/}
  kubectl -n $ns patch gateway $n --type merge -p "{\"spec\":{\"infrastructure\":{\"parametersRef\":{\"group\":\"gateway.k8s.f5.com\",\"kind\":\"GatewaySettings\",\"name\":\"$n-settings\"}}}}"
done

echo "== wait for Programmed"
kubectl -n default wait infra/bnk-infra --for=condition=Programmed --timeout=300s || true
for g in $GW; do ns=${g%/*}; n=${g#*/}
  kubectl -n $ns wait gateway/$n --for=condition=Programmed --timeout=180s || true
done
kubectl -n default get infra bnk-infra -o json | python3 -c 'import json,sys; [print(c["type"],c["status"],c.get("message","")[:160]) for c in json.load(sys.stdin)["status"]["conditions"]]'
kubectl get gatewaysettings -A
kubectl get gateway -A
