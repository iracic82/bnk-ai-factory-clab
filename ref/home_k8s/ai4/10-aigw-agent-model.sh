#!/usr/bin/env bash
# Add qwen2.5-3b (tool-calling capable, CPU) to tenant "lab" and issue a dedicated virtual key for kagent.
set -uo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
API=http://127.0.0.1:18443; TA=$API/api/v1/tenants/lab; NEW=qwen2.5-3b
U=$(kubectl get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)
TOK=$(jq -n --arg u "$U" --arg p "$P" '{username:$u,password:$p}' | curl -sS $API/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @- | jq -r .access_token); unset P
j() { curl -sS "$@" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json'; }
REF=$(j $TA/provider-keys | jq -r '(.data // .items)[]? | select(.name=="lab-ollama") | .ref' | head -1)
jq -n --arg n $NEW --arg p "$REF" '{name:$n,deployments:[{providerRef:$p,upstream:"qwen2.5:3b",dialects:["openai"]}]}' \
  | j $TA/models --data-binary @- | jq -c '{model:(.data.name // .error // .)}'
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
add_scope governance/principals lab-app
add_scope virtual-keys $(j $TA/virtual-keys | jq -r '(.data // .items)[]? | select(.name=="lab-app-key") | .id')
if [ ! -s /root/ai4/kagent-virtual-key ]; then
  PK=$(j $TA/provider-keys | jq -c '[(.data // .items)[]? | .ref]')
  jq -n --argjson p "$PK" '{name:"kagent-key",principalId:"lab-app",providerKeys:$p,modelScope:["qwen2.5-3b","qwen2.5-0.5b","llama3.2-1b"]}' \
    | j $TA/virtual-keys --data-binary @- | jq -r '.data.token // empty' > /root/ai4/kagent-virtual-key
  chmod 600 /root/ai4/kagent-virtual-key
fi
[ -s /root/ai4/kagent-virtual-key ] && echo "kagent key ready" || echo "kagent key FAILED"
K=$(cat /root/ai4/kagent-virtual-key)
curl -sS -m 180 http://10.10.12.33/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-3b","messages":[{"role":"user","content":"Reply with exactly: ready"}],"max_tokens":8}' | jq -c '{model, reply:.choices[0].message.content, err:.error}'
