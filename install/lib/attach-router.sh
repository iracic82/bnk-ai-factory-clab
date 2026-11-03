#!/usr/bin/env bash
# Attach the semantic router to the lab tenant's AI Gateway profile, or attach it again after the router pods were
# replaced: Polaris resolves the Service when the hook is programmed (EVE lab, ai4/aigw-reattach-router.sh). The
# router downloads its models on first start, so this waits for a Ready pod before it programs anything.
# Usage: attach-router.sh [wait-seconds]   default 3600, 0 means do not wait for the pods.
# install/40-ai.sh runs it in the background at track start; chapter 15 runs it by hand.
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-/root/lab/clab/kubeconfig}"
NS=f5-bnk; API="${API:-http://127.0.0.1:18443}"; T="${ROUTER_TENANT:-lab}"; WAIT="${1:-3600}"
log() { echo "$(date -u +%H:%M:%S) $*"; }
ready() { kubectl -n $NS get pod -l app=semantic-router -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | tr ' ' '\n' | grep -c True; }
if [ "$WAIT" -gt 0 ]; then
  for _ in $(seq 1 $((WAIT / 10))); do [ "$(ready)" -ge 1 ] && break; sleep 10; done
fi
log "semantic-router: $(ready) Ready pod(s)"
[ "$(ready)" -ge 1 ] || { log "no Ready router pod; nothing attached. Run again later: bash $0"; exit 1; }
U=$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)
TOK=$(jq -n --arg u "$U" --arg p "$P" '{username:$u,password:$p}' | curl -sS "$API/api/v1/auth/login" -H 'Content-Type: application/json' --data-binary @- | jq -er .access_token) || { log "admin login failed on $API"; exit 1; }
unset U P
j() { curl -sS "$@" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json'; }
TA="$API/api/v1/tenants/$T"
PROF=$(j "$TA/profiles" | jq -r --arg n "$T-ai" '(.data // .items)[]? | select(.name==$n) | .name' | head -1)
[ -n "$PROF" ] || PROF=$(j "$TA/profiles" | jq -r '(.data // .items)[0].name // empty')
[ -n "$PROF" ] || { log "tenant $T has no AI Gateway profile yet"; exit 1; }
cur=$(j "$TA/profiles/$PROF/semantic-router"); log "profile $PROF, current hook: $(echo "$cur" | head -c 200)"
# a hook that is already configured is removed first (the gateway resolved the old pod); an empty one answers 405 to DELETE
if echo "$cur" | jq -e '(.data // .) | .configured == true' >/dev/null 2>&1; then
  log "delete: HTTP $(j -X DELETE "$TA/profiles/$PROF/semantic-router" -o /dev/null -w '%{http_code}')"
  sleep 3
fi
log "put: $(j -X PUT "$TA/profiles/$PROF/semantic-router" --data-binary '{"name":"semantic-router","port":50051,"timeoutMs":1000}' | head -c 300)"
unset TOK
if kubectl -n $NS wait --for=condition=Programmed "aigatewayprofiles.inference.k8s.f5.com/$PROF" --timeout=180s >/dev/null 2>&1; then
  log "profile $PROF Programmed with the router: model \"auto\" on the lab route is routed"
else
  log "profile $PROF not Programmed within 180s: kubectl -n $NS get aigatewayprofiles.inference.k8s.f5.com $PROF -o yaml"; exit 1
fi
