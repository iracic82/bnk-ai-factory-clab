#!/usr/bin/env bash
# One screen of lab state, for pasting. Nothing here changes anything.
# Usage: bash /root/lab/instruqt/bnk-ai-factory-clab/build/status.sh
export KUBECONFIG="${KUBECONFIG:-/root/lab/clab/kubeconfig}"
h() { printf '\n### %s  (%s UTC)\n' "$1" "$(date -u +%H:%M:%S)"; }

h "lab containers"; docker ps --format '{{.Names}}\t{{.Status}}' | sort | tr '\n' ';' | sed 's/;/ ; /g'; echo
h "nodes"; kubectl get nodes -o wide --no-headers | awk '{print $1, $2, $5, $6}'
h "CNEInstance"; kubectl -n f5-bnk get cneinstance f5-bnk-instance -o jsonpath='manifest={.spec.manifestVersion} dyn={.spec.dynamicRouting.enabled} ai={.spec.aiGateway.enabled} ilb={.spec.intelligentLB.enabled}{"\n"}{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' 2>&1
h "TMM"; kubectl -n f5-bnk get pod -l app=f5-tmm -o wide --no-headers 2>&1
kubectl -n f5-bnk get pod -l app=f5-tmm -o jsonpath='gates={.items[0].spec.readinessGates}{"\n"}{range .items[0].status.conditions[*]}  {.type}={.status} {.reason} {.message}{"\n"}{end}image={.items[0].spec.containers[0].image}{"\n"}' 2>&1
h "licence"; kubectl -n f5-bnk get f5biglicense,f5biglicenseconfig -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.status.status}{"\n"}{end}' 2>/dev/null || kubectl -n f5-bnk get cm -l app=f5-license -o name 2>/dev/null
h "pods not Running/Completed"; kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || echo "none"
h "BGP on leaf1"; docker exec leaf1 vtysh -c 'show bgp vrf all summary' 2>&1 | grep -E 'VRF|65100|65000' || echo "no sessions"
h "type-5 routes on r5"; docker exec r5 vtysh -c 'show ip route vrf all' 2>&1 | grep -cE '^B' | sed 's/^/BGP routes: /'
h "VIPs from the client"; for t in a b c; do vip="10.20$(printf '%d' "$(( $(printf '%d' "'$t") - 96 ))").100.10"; printf '  tenant-%s %-16s ' "$t" "$vip"; docker exec client curl -s -m 5 -o /dev/null -w '%{http_code}\n' "http://$vip/" || echo "no answer"; done
h "AI layer"; kubectl get pods -n aigw-models --no-headers 2>&1 | awk '{print "  "$1, $2, $3}'
kubectl get inferencepool,f5epp -A --no-headers 2>/dev/null | sed 's/^/  /'
h "agents / sandboxes / guardrails"; for ns in kagent openshell agent-substrate guardrails tenant-a tenant-b tenant-c; do kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk -v ns="$ns" '{print "  "ns"/"$1, $2, $3}'; done
h "mirror cache"; du -sh /var/lib/bnk-mirrors/* 2>/dev/null | awk '{print "  "$1, $2}'
ls /var/lib/bnk-mirrors/repo.f5.com/docker/registry/v2/repositories 2>/dev/null | wc -l | sed 's/^/  repo.f5.com repositories cached: /'
