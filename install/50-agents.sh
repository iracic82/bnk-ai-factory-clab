#!/usr/bin/env bash
# The agent layer: kagent 0.10.4 (controller, UI, k8s tool server) with its model from the Polaris AI Gateway, the
# operator's agent, one agent app + kagent Agent per tenant (its own MCP server, its own AI Gateway key, its own
# published VIP), NVIDIA OpenShell (gateway + Agent Sandbox controller, one sandbox per tenant whose only credential
# is injected toward that tenant's AI Gateway), and Agent Substrate v0.0.11 (the release kagent 0.10.4 accepts) so
# the sanctioned agents can run as SandboxAgents on a WorkerPool. The shadow agent is NOT deployed: chapter 9 does.
#
# Order: kagent first (CRDs the tenant overlays need), then tenants, then OpenShell, then Substrate (its install needs
# the beta certificate APIs, enabled in clab/kind-config.yaml, and a Go toolchain for the upstream installer).
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/expose.sh"
need helm; need jq
M="$REPO_ROOT/manifests/agents"; NS=f5-bnk
KAGENT=0.10.4; SUBSTRATE=0.0.11; OPENSHELL=0.1.5; SANDBOX=v1.0.7; GO=1.24.9
[ -s "$SECRETS_DIR/aigw/lab.key" ] || fail "no AI Gateway key for tenant lab; run 40-ai.sh"
KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Subnet}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/' | head -1)
INTERNAL_SELFIP="$(echo "${KIND_SUBNET%/*}" | cut -d. -f1-3).250"     # TMM's internal self IP (35-bnk-network.sh)
KIND_GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)

step "kagent $KAGENT"
kubectl create ns kagent --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n kagent create secret generic kagent-openai --from-literal=OPENAI_API_KEY="$(tr -d ' \n\r' < "$SECRETS_DIR/aigw/lab.key")" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install kagent-crds oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds --version $KAGENT -n kagent --wait >/dev/null
# Substrate is switched on in the values, but its CRDs come later; install kagent with the pool creation off first
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version $KAGENT -n kagent -f "$M/kagent-values.yaml" \
  --set controller.substrate.enabled=false --set substrateWorkerPool.create=false --wait --timeout "$(tmo 15m 6m)" >/dev/null
kubectl apply -f "$M/platform-agent.yaml" >/dev/null
expose_service kagent-ui kagent kagent-ui 30808 8080
ok "kagent up; operator agent factory-operator; UI on :30808"

step "tenant agents (app + MCP server + kagent Agent, each in its tenant namespace)"
for t in a b c; do
  ns=tenant-$t
  [ -s "$SECRETS_DIR/aigw/$ns.key" ] || { warn "no AI Gateway key for $ns, skipping"; continue; }
  kubectl -n "$ns" create secret generic aigw-key --from-literal=token="$(tr -d ' \n\r' < "$SECRETS_DIR/aigw/$ns.key")" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl kustomize "$M/tenant-agent/tenants/$ns" | sed "s|__INTERNAL_SELFIP__|$INTERNAL_SELFIP|g" | kubectl apply -f - >/dev/null
  kubectl -n "$ns" rollout status deploy/agent --timeout=300s >/dev/null && ok "$ns agent running" || warn "$ns agent not up yet"
done

step "NVIDIA OpenShell $OPENSHELL (gateway + Agent Sandbox controller $SANDBOX)"
kubectl apply -f "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$SANDBOX/sandbox.yaml" >/dev/null
kubectl -n agent-sandbox-system rollout status deploy --timeout=300s >/dev/null
W="$REPO_ROOT/.cache/openshell-$OPENSHELL"; mkdir -p "$W"
[ -d "$W/deploy/helm/openshell" ] || curl -sSfL "https://github.com/NVIDIA/OpenShell/archive/refs/tags/v$OPENSHELL.tar.gz" | tar -xz -C "$W" --strip-components=1
kubectl create ns openshell --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install openshell "$W/deploy/helm/openshell" -n openshell --wait --timeout 10m >/dev/null
kubectl -n openshell rollout status statefulset/openshell --timeout=300s >/dev/null 2>&1 || kubectl -n openshell rollout status deploy --timeout=300s >/dev/null
if ! command -v openshell >/dev/null; then
  R="https://github.com/NVIDIA/OpenShell/releases/download/v$OPENSHELL"; T=$(mktemp -d)
  ( cd "$T" && curl -sSfLO "$R/openshell-x86_64-unknown-linux-musl.tar.gz" -O "$R/openshell-checksums-sha256.txt" \
    && grep ' openshell-x86_64-unknown-linux-musl.tar.gz$' openshell-checksums-sha256.txt | sha256sum -c - >/dev/null \
    && tar xzf openshell-x86_64-unknown-linux-musl.tar.gz && sudo install -m 0755 "$(find . -type f -name openshell | head -1)" /usr/local/bin/openshell )
  rm -rf "$T"
fi
ok "openshell $(openshell --version 2>/dev/null | head -1)"
# one provider per tenant: the sandbox gets the key only toward that tenant's route
declare -A DISPLAY=( [a]="Aurora Health" [b]="Borealis Bank" [c]="Cobalt Labs" )
for t in a b c; do
  ns=tenant-$t; host="172.16.100.2$(( $(printf '%d' "'$t") - 97 ))"
  sed -e "s/__TENANT__/$ns/g" -e "s/__DISPLAY__/${DISPLAY[$t]}/g" -e "s/__HOST__/$host/g" "$M/openshell-profile.yaml" > "$REPO_ROOT/.cache/openshell-profile-$ns.yaml"
  openshell provider profile lint -f "$REPO_ROOT/.cache/openshell-profile-$ns.yaml" >/dev/null && \
  openshell provider profile import -f "$REPO_ROOT/.cache/openshell-profile-$ns.yaml" --global >/dev/null 2>&1 || true
  AIGW_API_KEY="$(tr -d ' \n\r' < "$SECRETS_DIR/aigw/$ns.key")" openshell provider create --name "f5-aigw-$ns" --type "f5-aigw-$ns" --credential AIGW_API_KEY >/dev/null 2>&1 || true
  # a long-running sandbox per tenant; chapter 7 shows its policy, chapter 11 shows it cannot reach the webhook
  openshell sandbox list 2>/dev/null | grep -q "^$ns-agent\b" || \
    openshell sandbox create --name "$ns-agent" --provider "f5-aigw-$ns" --env "OPENAI_BASE_URL=http://$host/v1" --no-tty -- sleep infinity >/dev/null 2>&1 &
done
for _ in $(seq 1 "$(tmo 60 12)"); do [ "$(openshell sandbox list 2>/dev/null | grep -c Ready)" -ge 3 ] && break; sleep 5; done
openshell sandbox list 2>/dev/null || warn "openshell sandbox list failed"

step "Agent Substrate $SUBSTRATE"
if ! command -v go >/dev/null || ! go version | grep -q "go$GO"; then
  curl -sSfL "https://go.dev/dl/go$GO.linux-amd64.tar.gz" | sudo tar -xz -C /usr/local && export PATH=/usr/local/go/bin:$PATH
fi
export PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=auto
helm upgrade --install substrate-crds oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds --version $SUBSTRATE -n ate-system --create-namespace --wait >/dev/null
helm upgrade --install substrate oci://ghcr.io/kagent-dev/substrate/helm/substrate --version $SUBSTRATE -n ate-system --set auth.mode=mtls >/dev/null
S="$REPO_ROOT/.cache/substrate-$SUBSTRATE"; mkdir -p "$S"
[ -f "$S/hack/install-ate.sh" ] || curl -sSfL "https://github.com/kagent-dev/substrate/archive/refs/tags/v$SUBSTRATE.tar.gz" | tar -xz -C "$S" --strip-components=1
( cd "$S" && [ -d .git ] || git init -q . ; for f in --create-podcertificate-controller-cas --create-actor-id-ca-pool-secret --create-jwt-authority-pool-secret --create-valkey-ca-certs-secret; do
    bash hack/install-ate.sh "$f" 2>&1 | grep -iE "created|error" | tail -1; done )
kubectl -n ate-system rollout status deploy --timeout="$(tmo 600s 180s)" >/dev/null 2>&1 || warn "substrate pods not all up yet"
# now kagent may own a WorkerPool
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version $KAGENT -n kagent -f "$M/kagent-values.yaml" --wait --timeout "$(tmo 15m 6m)" >/dev/null
kubectl -n kagent get workerpools.ate.dev 2>/dev/null || warn "no WorkerPool yet"
ok "Substrate installed; kagent substrate integration on"

step "what the learner sees"
kubectl get agents.kagent.dev -A
kubectl -n openshell get pods --no-headers | awk '{print "  openshell", $1, $3}'
