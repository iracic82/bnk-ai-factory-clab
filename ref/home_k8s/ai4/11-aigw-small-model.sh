#!/usr/bin/env bash
# Add qwen2.5-1.5b to tenant "lab" and allow it on every scope that has qwen2.5-3b. It is the smallest model that still
# calls tools correctly on CPU (0.5b writes the call as text, llama3.2-1b mangles arguments), and about twice as fast
# as 3b, so kagent and the AI Factory Agent use it. Run on bnk-cp1 as root. Needs `ollama pull qwen2.5:1.5b`.
set -uo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
API=http://127.0.0.1:18443; TA=$API/api/v1/tenants/lab; NEW=qwen2.5-1.5b
U=$(kubectl get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)
TOK=$(jq -n --arg u "$U" --arg p "$P" '{username:$u,password:$p}' | curl -sS $API/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @- | jq -r .access_token); unset P
j() { curl -sS "$@" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json'; }
REF=$(j $TA/provider-keys | jq -r '(.data // .items)[]? | select(.name=="lab-ollama") | .ref' | head -1)
jq -n --arg n $NEW --arg p "$REF" '{name:$n,deployments:[{providerRef:$p,upstream:"qwen2.5:1.5b",dialects:["openai"]}]}' \
  | j $TA/models --data-binary @- | jq -c 'if .data then {model:.data.name} else (.error.message // .error // .) end'
add_scope() { # $1 collection, $2 id
  cur=$(j $TA/$1 | jq -c --arg i "$2" '(.data // .items)[]? | select(.id==$i)')
  new=$(echo "$cur" | jq -c --arg m $NEW '.modelScope |= ((. // []) + [$m] | unique) | {modelScope}')
  for M in PATCH PUT; do
    r=$(echo "$new" | j -X $M $TA/$1/$2 --data-binary @- -o /dev/null -w '%{http_code}')
    [ "${r:0:1}" = 2 ] && { echo "$1/$2 scope updated ($M)"; return; }
  done; echo "$1/$2 scope update failed ($r)"
}
add_scope governance/orgs lab-org
add_scope governance/teams $(j $TA/governance/teams | jq -r '(.data // .items)[]? | select(.name=="lab-apps") | .id')
for p in lab-app openshell-agent; do add_scope governance/principals $p; done
for k in lab-app-key kagent-key agentic-app-key openshell-agent-key; do
  add_scope virtual-keys $(j $TA/virtual-keys | jq -r --arg k $k '(.data // .items)[]? | select(.name==$k) | .id')
done
R='redis-cli --tls --cert /tls/dssm/mds/svr/tls.crt --key /tls/dssm/mds/svr/tls.key --cacert /tls/dssm/mds/svr/ca.crt -p 6379'
for d in 0 1 2; do kubectl exec f5-dssm-db-$d -c f5-dssm -- sh -c "$R BGSAVE" >/dev/null 2>&1; done
K=$(cat /root/ai4/kagent-virtual-key)
curl -sS -m 180 http://10.10.12.33/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-1.5b","messages":[{"role":"user","content":"Reply with exactly: ready"}],"max_tokens":8}' | jq -c '{model, reply:.choices[0].message.content, err:.error}'
