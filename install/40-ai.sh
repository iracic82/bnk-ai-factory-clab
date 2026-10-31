#!/usr/bin/env bash
# The AI layer on top of BNK: the Gateway API Inference Extension CRDs, NVIDIA Dynamo (platform + NATS) with two
# GPU-free Mocker workers, the model pool behind its own BNK VIP with F5's Endpoint Picker, a small CPU model for
# the agents (ollama on the VM, so its weights are part of the baked image), the Polaris AI Gateway with one tenant
# per lab tenant (providers, models, virtual keys, a route on its own VIP), and NVIDIA's simulators for the GPU
# side: fake GPU operator (4 x H100 per worker) and the KAI scheduler with one queue per tenant.
#
# Idempotent: every create tolerates "already there"; keys are written once and kept in $SECRETS_DIR/aigw/.
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/expose.sh"
need helm; need jq; need docker
M="$REPO_ROOT/manifests/ai"; NS=f5-bnk
kubectl -n $NS get cneinstance f5-bnk-instance >/dev/null || fail "no CNEInstance; run 30-bnk.sh"
KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Subnet}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/' | head -1)
KIND_GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)
[ -n "$KIND_SUBNET" ] && [ -n "$KIND_GW" ] || fail "cannot read the kind network"
GAIE=$GAIE_VERSION; DYNAMO=1.5.1; FGO=0.2.1; KAI=v0.18.6; OLLAMA_IMG=ollama/ollama:0.6.8

step "Gateway API Inference Extension CRDs $GAIE"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$GAIE/manifests.yaml" >/dev/null
step "namespaces and pull secrets"
kubectl create ns aigw-models --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label ns aigw-models aigw.lab/engine=dynamo --overwrite >/dev/null
for n in far-pull-secret far-secret; do   # the picker image comes from repo.f5.com
  kubectl -n $NS get secret far-pull-secret -o json \
    | jq --arg n "$n" 'del(.metadata.namespace,.metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,.metadata.ownerReferences,.metadata.managedFields) | .metadata.name=$n' \
    | kubectl -n aigw-models apply -f - >/dev/null
done

step "NVIDIA Dynamo platform $DYNAMO + NATS"
helm upgrade --install dynamo-platform "https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-$DYNAMO.tgz" \
  -n dynamo-system --create-namespace --set global.nats.install=true --wait --timeout "$(tmo 15m 5m)" >/dev/null
kubectl -n dynamo-system rollout status statefulset/dynamo-platform-nats --timeout=300s >/dev/null
kubectl apply -f "$M/11-nats-policy.yaml" >/dev/null
kubectl -n aigw-models create secret generic hf-token-secret --from-literal=HF_TOKEN= --dry-run=client -o yaml | kubectl apply -f - >/dev/null
step "Mocker workers (DynamoGraphDeployment)"
kubectl apply -f "$M/10-dynamo-mocker.yaml" >/dev/null
kubectl -n aigw-models wait dynamographdeployment/mocker --for=condition=Ready --timeout="$(tmo 1200s 300s)" >/dev/null && ok "mocker Ready" || warn "mocker not Ready yet (continuing)"

step "model pool behind its own VIP with the F5 Endpoint Picker"
kubectl apply -f "$M/20-pool-vip.yaml" >/dev/null
INTERNAL_SELFIP="$(echo "${KIND_SUBNET%/*}" | cut -d. -f1-3).250"     # same rule as install/35-bnk-network.sh
sed "s|__INTERNAL_SELFIP__|$INTERNAL_SELFIP|g" "$M/50-netpol.yaml" | kubectl apply -f - >/dev/null
# the controller creates the picker Deployment from the F5EPP a few minutes after the CR lands (4-5 min on the bake VM)
for _ in $(seq 1 "$(tmo 120 60)"); do kubectl -n aigw-models get deploy model-pool-epp >/dev/null 2>&1 && break; sleep 5; done
kubectl -n aigw-models get deploy model-pool-epp >/dev/null 2>&1 || warn "no model-pool-epp Deployment yet (the controller has not acted on the F5EPP)"
kubectl -n aigw-models rollout status deploy/model-pool-epp --timeout="$(tmo 600s 180s)" >/dev/null 2>&1 && ok "picker running" || warn "picker not up yet"

step "ollama on the VM for the agents' model (qwen2.5:1.5b)"
# A container on the VM, bound to the kind gateway address and loopback only: pods reach it over the node network,
# nothing on the LAN does, and /var/lib/lab-ollama (the weights) is part of the baked image.
sudo mkdir -p /var/lib/lab-ollama
docker ps -a --format '{{.Names}}' | grep -qx lab-ollama || docker run -d --name lab-ollama --restart unless-stopped \
  -p "$KIND_GW:11434:11434" -p 127.0.0.1:11434:11434 -v /var/lib/lab-ollama:/root/.ollama \
  -e OLLAMA_KEEP_ALIVE=-1 -e OLLAMA_NUM_PARALLEL=4 -e OLLAMA_CONTEXT_LENGTH=8192 --cpus 8 --memory 12g "$OLLAMA_IMG" >/dev/null
for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://127.0.0.1:11434/api/version" && break; sleep 2; done
for m in qwen2.5:1.5b qwen2.5:0.5b; do
  docker exec lab-ollama ollama list 2>/dev/null | grep -q "^$m" || docker exec lab-ollama ollama pull "$m" >/dev/null
  # one thread per allowed core, else ollama starts a thread per visible core and CFS throttling cuts generation to a crawl
  docker exec lab-ollama sh -c "printf 'FROM %s\nPARAMETER num_thread 8\n' '$m' > /tmp/Modelfile && ollama create '$m' -f /tmp/Modelfile" >/dev/null 2>&1 || true
done
curl -sS -m 5 http://127.0.0.1:11434/api/generate -d '{"model":"qwen2.5:1.5b","keep_alive":-1}' >/dev/null 2>&1 || true
ok "ollama at $KIND_GW:11434 with $(docker exec lab-ollama ollama list | tail -n +2 | wc -l) models"

step "Polaris AI Gateway: Reconciled, console and management API on the host"
r=""
for i in $(seq 1 "$(tmo 90 18)"); do
  r=$(kubectl -n $NS get aigateways.k8s.f5.com -o jsonpath='{.items[0].status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null || true)
  [ "$r" = True ] && break; sleep 20
done
[ "$r" = True ] || fail "AIGateway not Reconciled after $(( $(tmo 90 18) / 3 )) minutes: kubectl -n $NS get aigateways.k8s.f5.com -o yaml"
kubectl -n $NS wait --for=condition=Ready pod/f5-aigateway-clickhouse-0 --timeout="$(tmo 600s 180s)" >/dev/null || warn "ClickHouse not Ready"
# the controller checks ClickHouse once at start and may have lost that race (seen on 2.4.1): one restart after ClickHouse is up
kubectl -n $NS rollout restart deploy/f5-cne-controller >/dev/null 2>&1 || true
kubectl -n $NS rollout status deploy/f5-cne-controller --timeout=300s >/dev/null 2>&1 || true
expose_service polaris $NS f5-aigateway-console 30443
LAB_PUBLIC=0 expose_service aigw-api $NS f5-cne-controller-api 18443
API=http://127.0.0.1:18443
for _ in $(seq 1 60); do curl -fsS -o /dev/null "$API/api/v1/admin/ready" && break; sleep 3; done
curl -fsS -o /dev/null "$API/api/v1/admin/ready" || fail "the management API is not ready on $API"

step "tenants in the AI Gateway (providers, models, keys, a route per tenant)"
mkdir -p "$SECRETS_DIR/aigw"; chmod 700 "$SECRETS_DIR/aigw"
TOK=$(jq -n --arg u "$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)" \
            --arg p "$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)" '{username:$u,password:$p}' \
      | curl -sS "$API/api/v1/auth/login" -H 'Content-Type: application/json' --data-binary @- | jq -er .access_token) || fail "admin login failed"
j() { curl -sS "$@" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json'; }
aigw_tenant() {   # name display vip
  local T=$1 D=$2 VIP=$3 TA="$API/api/v1/tenants/$1" r ref
  jq -n --arg n "$T" --arg d "$D" '{name:$n,displayName:$d}' | j "$API/api/v1/tenants" --data-binary @- >/dev/null
  kubectl -n $NS wait --for=condition=Ready "aitenants.inference.k8s.f5.com/$T" --timeout=180s >/dev/null || warn "tenant $T not Ready"
  declare -A REF=()
  for spec in "dynamo|http://mocker-frontend.aigw-models.svc.cluster.local:8000/v1" "ollama|http://$KIND_GW:11434/v1"; do
    local n=${spec%%|*} url=${spec#*|}
    r=$(jq -n --arg n "$T-$n" --arg u "$url" '{name:$n,vendor:"Generic",value:"not-needed",enabled:true,generic:{baseURL:$u}}' | j "$TA/provider-keys" --data-binary @-)
    ref=$(echo "$r" | jq -r '.data.ref // empty'); [ -z "$ref" ] && ref=$(j "$TA/provider-keys" | jq -r --arg n "$T-$n" '(.data // .items)[]? | select(.name==$n) | .ref' | head -1)
    REF[$n]=$ref
  done
  local MODELS=()
  for spec in "qwen3-0.6b-dynamo|dynamo|Qwen/Qwen3-0.6B" "qwen2.5-1.5b|ollama|qwen2.5:1.5b" "qwen2.5-0.5b|ollama|qwen2.5:0.5b"; do
    IFS='|' read -r name prov up <<<"$spec"; MODELS+=("$name")
    jq -n --arg n "$name" --arg p "${REF[$prov]}" --arg u "$up" '{name:$n,deployments:[{providerRef:$p,upstream:$u,dialects:["openai"]}]}' | j "$TA/models" --data-binary @- >/dev/null
  done
  # 2.4.2's management API lists as {items:[...]} and answers a create with the object itself; 2.4.1 (EVE) wrapped
  # both in {data:...}. Both shapes are read, and a create that yields nothing prints the API's answer.
  local SCOPE PKEYS TEAM r; SCOPE=$(printf '%s\n' "${MODELS[@]}" | jq -R . | jq -sc .); PKEYS=$(printf '%s\n' "${REF[@]}" | jq -R . | jq -sc .)
  if ! j "$TA/governance/orgs" | jq -e --arg i "$T-org" '(.data // .items)[]? | select(.id==$i)' >/dev/null 2>&1; then
    r=$(jq -n --arg i "$T-org" --arg d "$D" --argjson s "$SCOPE" '{id:$i,name:$i,displayName:$d,modelScope:$s}' | j "$TA/governance/orgs" --data-binary @-)
    echo "$r" | jq -e '(.data.id // .id) != null' >/dev/null 2>&1 || warn "$T: org $T-org not created: $(echo "$r" | head -c 300)"
  fi
  # 2.4.2 rejects whitespace in a team name ("team name must not contain whitespace"): slug name, display name apart
  team_id() { j "$TA/governance/teams" | jq -r --arg n "$T-apps" --arg o "$T-org" '(.data // .items)[]? | select(.name==$n and .orgId==$o) | .id' | head -1; }
  TEAM=$(team_id)
  if [ -z "$TEAM" ]; then
    r=$(jq -n --arg n "$T-apps" --arg d "$D apps" --arg o "$T-org" --argjson s "$SCOPE" '{name:$n,displayName:$d,orgId:$o,modelScope:$s}' | j "$TA/governance/teams" --data-binary @-)
    TEAM=$(echo "$r" | jq -r '.data.id // .id // empty'); [ -n "$TEAM" ] || TEAM=$(team_id)
    [ -n "$TEAM" ] || warn "$T: team not created: $(echo "$r" | head -c 300)"
  fi
  r=$(jq -n --arg i "$T-app" --arg t "$TEAM" --argjson s "$SCOPE" '{id:$i,name:$i,kind:"service",teamId:$t,role:"member",active:true,modelScope:$s}' | j "$TA/governance/principals" --data-binary @-)
  echo "$r" | jq -e '(.data.id // .id) != null' >/dev/null 2>&1 || j "$TA/governance/principals" | jq -e --arg i "$T-app" '(.data // .items)[]? | select(.id==$i)' >/dev/null 2>&1 \
    || warn "$T: principal $T-app not created: $(echo "$r" | head -c 300)"
  if [ ! -s "$SECRETS_DIR/aigw/$T.key" ]; then
    r=$(jq -n --arg n "$T-app-key" --arg p "$T-app" --argjson k "$PKEYS" --argjson s "$SCOPE" '{name:$n,principalId:$p,providerKeys:$k,modelScope:$s}' | j "$TA/virtual-keys" --data-binary @-)
    echo "$r" | jq -r '.data.token // .token // empty' > "$SECRETS_DIR/aigw/$T.key"; chmod 600 "$SECRETS_DIR/aigw/$T.key"
    [ -s "$SECRETS_DIR/aigw/$T.key" ] || warn "$T: virtual key not created: $(echo "$r" | head -c 300)"
  fi
  [ -s "$SECRETS_DIR/aigw/$T.key" ] || warn "no virtual key for $T"
  jq -n --arg n "$T-ai" --arg a "$VIP" '{name:$n,address:$a,gatewayClassName:"f5-gateway-class"}' | j "$TA/routes" --data-binary @- >/dev/null
  kubectl -n $NS wait --for=condition=Programmed "gateway/$T-ai" --timeout=240s >/dev/null && ok "$T: route $T-ai on $VIP, ${#MODELS[@]} models, key in $SECRETS_DIR/aigw/$T.key" || warn "$T: gateway $T-ai not Programmed"
}
aigw_tenant lab      "AI Factory"    172.16.100.13
aigw_tenant tenant-a "Aurora Health" 172.16.100.20
aigw_tenant tenant-b "Borealis Bank" 172.16.100.21
aigw_tenant tenant-c "Cobalt Labs"   172.16.100.22
unset TOK

step "GPU simulators: fake GPU operator $FGO (4 x H100 per worker) and KAI scheduler $KAI with a queue per tenant"
for n in bnk-worker bnk-worker2; do kubectl label node $n run.ai/simulated-gpu-node-pool=h100 --overwrite >/dev/null; done
helm upgrade -i gpu-operator oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator --version $FGO -n gpu-operator --create-namespace -f "$M/40-fake-gpu-values.yaml" --wait --timeout 5m >/dev/null
helm upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler --version $KAI -n kai-scheduler --create-namespace -f "$M/41-kai-values.yaml" --wait --timeout 5m >/dev/null
until kubectl -n kai-scheduler get deploy queue-controller >/dev/null 2>&1; do sleep 3; done
kubectl -n kai-scheduler rollout status deploy --timeout 5m >/dev/null
until kubectl apply -f "$M/42-queues.yaml" >/dev/null 2>&1; do sleep 5; done
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
kubectl get queues.scheduling.run.ai

step "the two paths to an AI Gateway route: the fabric (client behind r5) and TMM's internal leg (a node, as pods do)"
K=$(cat "$SECRETS_DIR/aigw/tenant-a.key" 2>/dev/null || true)
[ -n "$K" ] && docker exec client curl -sS -m 120 http://172.16.100.20/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-1.5b","messages":[{"role":"user","content":"Reply with exactly: ready"}],"max_tokens":8}' | jq -c '{model, reply:.choices[0].message.content, err:.error}' || warn "no tenant-a key to test with"
unset K
# kagent and the sandboxes reach the lab route on 172.16.100.13 through the node route added in 35-bnk-network.sh
L=$(cat "$SECRETS_DIR/aigw/lab.key" 2>/dev/null || true)
for n in bnk-control-plane bnk-worker; do
  code=$(docker exec "$n" curl -s -m 15 -o /dev/null -w '%{http_code}' http://172.16.100.13/v1/models -H "Authorization: Bearer $L" || echo 000)
  [ "$code" = 200 ] && ok "$n -> 172.16.100.13 via TMM's internal leg: $code" || warn "$n -> 172.16.100.13 answered $code (the node route or the internal leg)"
done
unset L
