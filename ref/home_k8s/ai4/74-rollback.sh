#!/bin/bash
# Roll 73-migrate.sh back: Gateways to F5BnkGateway / static addresses, controller flag off.
# The legacy F5SPKVlan "external" and F5BnkGateway were never deleted, so they take over again.
set -uo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
LEG='{"spec":{"infrastructure":{"parametersRef":{"group":"k8s.f5net.com","kind":"F5BnkGateway","name":"f5-bnkgateway"}}}}'
for g in demo/demo-gw lab-local/bnk-vip kagent/agents-gw; do kubectl -n ${g%/*} patch gateway ${g#*/} --type merge -p "$LEG"; done
for g in default/pool-vip default/lab-ai; do kubectl -n ${g%/*} patch gateway ${g#*/} --type json -p '[{"op":"remove","path":"/spec/infrastructure"}]'; done
kubectl patch cneinstance bnk-eve -n default --type merge -p '{"spec":{"advanced":{"cneController":{"env":[{"name":"TMM_DEFAUlT_MTU","value":"1500"}]}}}}'
sleep 20; kubectl -n default rollout status deploy/f5-cne-controller --timeout=300s
kubectl get gateway -A; kubectl get f5-spk-vlans,f5-bnkgateways -A
