#!/usr/bin/env bash
# AI Gateway (Polaris) tenant "lab": Generic providers for Ollama / Dynamo mocker / GPU sim, models, key, route.
set -uo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
API=http://127.0.0.1:18443; NS=default; T=lab; VIP=172.16.100.13
j() { curl -sS "$@" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json'; }
U=$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)
TOK=$(jq -n --arg u "$U" --arg p "$P" '{username:$u,password:$p}' | curl -sS $API/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @- | jq -r .access_token); unset P
[ -n "$TOK" ] && [ "$TOK" != null ] || { echo "login failed"; exit 1; }
echo "== tenant"; jq -n --arg n $T '{name:$n,displayName:"BNK EVE Lab"}' | j $API/api/v1/tenants --data-binary @- | jq -c '.data.name // .'
kubectl wait --for=condition=Ready aitenants.inference.k8s.f5.com/$T -n $NS --timeout=180s
TA=$API/api/v1/tenants/$T
declare -A REF
for spec in "ollama|http://ollama.llm-light.svc.cluster.local:11434/v1" \
            "dynamo|http://mocker-frontend.aigw-models.svc.cluster.local:8000/v1" \
            "gpusim|http://sim.nim.svc.cluster.local:8080/v1"; do
  n=${spec%%|*}; url=${spec#*|}
  r=$(jq -n --arg n "$T-$n" --arg u "$url" '{name:$n,vendor:"Generic",value:"not-needed",enabled:true,generic:{baseURL:$u}}' | j $TA/provider-keys --data-binary @-)
  ref=$(echo "$r" | jq -r '.data.ref // empty'); [ -z "$ref" ] && ref=$(j $TA/provider-keys | jq -r --arg n "$T-$n" '.data[]? | select(.name==$n) | .ref' | head -1)
  REF[$n]=$ref; echo "provider $n -> ${ref:-ERROR $(echo $r | head -c 200)}"
done
MODELS=()
for spec in "qwen2.5-0.5b|ollama|qwen2.5:0.5b" "llama3.2-1b|ollama|llama3.2:1b" "smollm2-360m|ollama|smollm2:360m" \
            "qwen3-0.6b-dynamo|dynamo|Qwen/Qwen3-0.6B" "llama-3.1-8b-sim|gpusim|meta/llama-3.1-8b-instruct"; do
  IFS='|' read -r name prov up <<<"$spec"; MODELS+=("$name")
  jq -n --arg n "$name" --arg p "${REF[$prov]}" --arg u "$up" '{name:$n,deployments:[{providerRef:$p,upstream:$u,dialects:["openai"]}]}' \
    | j $TA/models --data-binary @- | jq -c '{model:(.data.name // .data.id // .error // .)}'
done
SCOPE=$(printf '%s\n' "${MODELS[@]}" | jq -R . | jq -sc .)
PKEYS=$(printf '%s\n' "${REF[@]}" | jq -R . | jq -sc .)
echo "== org/team/principal"
jq -n --argjson s "$SCOPE" '{id:"lab-org",name:"Lab",modelScope:$s}' | j $TA/governance/orgs --data-binary @- | jq -c '.data.id // .'
TEAM=$(j $TA/governance/teams | jq -r '.data[]? | select(.name=="Lab Apps") | .id' | head -1)
[ -z "$TEAM" ] && TEAM=$(jq -n --argjson s "$SCOPE" '{name:"Lab Apps",orgId:"lab-org",modelScope:$s}' | j $TA/governance/teams --data-binary @- | jq -r .data.id)
jq -n --arg t "$TEAM" --argjson s "$SCOPE" '{id:"lab-app",name:"lab-app",kind:"service",teamId:$t,role:"member",active:true,modelScope:$s}' | j $TA/governance/principals --data-binary @- | jq -c '.data.id // .'
echo "== virtual key"
if [ ! -s /root/ai3/virtual-key ]; then
  K=$(jq -n --argjson p "$PKEYS" --argjson s "$SCOPE" '{name:"lab-app-key",principalId:"lab-app",providerKeys:$p,modelScope:$s}' | j $TA/virtual-keys --data-binary @-)
  echo "$K" | jq -r '.data.token // empty' > /root/ai3/virtual-key; chmod 600 /root/ai3/virtual-key
  [ -s /root/ai3/virtual-key ] || echo "key error: $(echo $K | head -c 300)"
fi
echo "== route"
jq -n --arg a $VIP '{name:"lab-ai",address:$a,gatewayClassName:"f5-gateway-class"}' | j $TA/routes --data-binary @- | jq -c '.data.name // .'
kubectl -n $NS wait --for=condition=Programmed gateway/lab-ai --timeout=240s
kubectl -n $NS wait --for=condition=Programmed aigatewayprofiles.inference.k8s.f5.com/lab-ai --timeout=240s
kubectl -n $NS get gateway lab-ai
echo SETUP DONE
