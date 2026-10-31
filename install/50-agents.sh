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
KAGENT=0.10.4; SUBSTRATE=0.0.9; OPENSHELL=0.1.5; SANDBOX=v1.0.7; GO=1.24.9
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
kubectl apply -f "$M/agents-gateway.yaml" >/dev/null     # A2A on VIP 172.16.100.14 (kagent-values a2aBaseUrl)
kubectl -n kagent wait --for=condition=Programmed gateway/agents-gw --timeout=240s >/dev/null && ok "agents gateway on 172.16.100.14" || warn "gateway agents-gw not Programmed"
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
# The published chart, not the source tree: the chart in the source tarball carries appVersion 0.0.0 (CI patches it
# at release), which became image tag 0.0.0 and the certgen pre-install job died on an image that does not exist
# (bake of 2026-10-31). oci://ghcr.io/nvidia/openshell/helm-chart 0.1.5 has appVersion 0.1.5; the EVE lab used the
# same chart (pulled as charts/helm-chart there).
kubectl create ns openshell --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# a release whose first install failed in a hook cannot be upgraded ("has no deployed releases"); start it over
case "$(helm -n openshell status openshell -o json 2>/dev/null | jq -r .info.status)" in
  failed|pending-install|pending-upgrade) helm -n openshell uninstall openshell --wait >/dev/null 2>&1 || true ;;
esac
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart --version "$OPENSHELL" -n openshell --wait --timeout 10m >/dev/null
kubectl -n openshell rollout status statefulset/openshell --timeout=300s >/dev/null 2>&1 || kubectl -n openshell rollout status deploy --timeout=300s >/dev/null
if ! command -v openshell >/dev/null; then
  R="https://github.com/NVIDIA/OpenShell/releases/download/v$OPENSHELL"; T=$(mktemp -d)
  ( cd "$T" && curl -sSfLO "$R/openshell-x86_64-unknown-linux-musl.tar.gz" -O "$R/openshell-checksums-sha256.txt" \
    && grep ' openshell-x86_64-unknown-linux-musl.tar.gz$' openshell-checksums-sha256.txt | sha256sum -c - >/dev/null \
    && tar xzf openshell-x86_64-unknown-linux-musl.tar.gz && sudo install -m 0755 "$(find . -type f -name openshell | head -1)" /usr/local/bin/openshell )
  rm -rf "$T"
fi
ok "openshell $(openshell --version 2>/dev/null | head -1)"
# The CLI talks to the gateway over mTLS with the bundle the chart generated (docs/kubernetes/setup.mdx: copy the
# openshell-client-tls Secret into the CLI's gateway directory, reach the Service locally, register with --local).
# The documented port-forward is replaced by the lab's socat unit on loopback; the server certificate's SANs
# include 127.0.0.1, so verification passes. Without this the CLI answers "No active gateway" (bake of 2026-10-31).
GWN=factory; GWD="$HOME/.config/openshell/gateways/$GWN/mtls"; mkdir -p "$GWD"; chmod 700 "$GWD"
for k in ca.crt tls.crt tls.key; do
  kubectl -n openshell get secret openshell-client-tls -o jsonpath="{.data.${k//./\\.}}" | base64 -d > "$GWD/$k"; chmod 600 "$GWD/$k"
done
LAB_PUBLIC=0 expose_service openshell-cli openshell openshell 18090 8080
openshell gateway list 2>/dev/null | grep -qw "$GWN" || openshell gateway add "https://127.0.0.1:18090" --local --name "$GWN" >/dev/null
openshell gateway select "$GWN" >/dev/null 2>&1 || true
openshell status 2>&1 | head -6 | sed 's/^/      /'

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
# the API, not api-resources' table (its NAME column is not the first thing on a line when a group is wide)
if ! kubectl get --raw /apis/certificates.k8s.io/v1beta1 2>/dev/null | grep -q '"podcertificaterequests"'; then
  warn "Substrate needs the PodCertificateRequest API (Kubernetes 1.34+); this cluster is $(kubectl version -o json 2>/dev/null | jq -r .serverVersion.gitVersion). Skipped; the sanctioned agents run as plain kagent Agents in their OpenShell sandboxes."
  kubectl get agents.kagent.dev -A; exit 0
fi
if ! command -v go >/dev/null || ! go version | grep -q "go$GO"; then
  curl -sSfL "https://go.dev/dl/go$GO.linux-amd64.tar.gz" | sudo tar -xz -C /usr/local && export PATH=/usr/local/go/bin:$PATH
fi
export PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=auto
# 0.0.9 is the Substrate the kagent 0.10.4 chart declares as its dependency (Chart.yaml) and its Go module pins.
# 0.0.11 was tried first: its router's agentgateway reads a servicedns credential bundle that the chart's volume never
# writes (fixed upstream in 0.0.13, which also moves to Postgres and a different bootstrap); 0.0.9's router does not
# use that bundle. mTLS mode, as on EVE: the CA and JWT pools come from the project's own bootstrap script, created
# BEFORE the chart so the pod certificate controller and the API server find them at first start.
S="$REPO_ROOT/.cache/substrate-$SUBSTRATE"; mkdir -p "$S"
[ -f "$S/hack/install-ate.sh" ] || curl -sSfL "https://github.com/kagent-dev/substrate/archive/refs/tags/v$SUBSTRATE.tar.gz" | tar -xz -C "$S" --strip-components=1
for ns in ate-system podcertificate-controller-system; do kubectl create ns $ns --dry-run=client -o yaml | kubectl apply -f - >/dev/null; done
( cd "$S" && { [ -d .git ] || git init -q . ; }
  for f in --create-podcertificate-controller-cas --create-session-id-ca-pool-secret --create-jwt-authority-pool-secret; do
    kubectl -n ate-system get secret session-id-ca-pool >/dev/null 2>&1 && [ "$f" = --create-session-id-ca-pool-secret ] && continue
    kubectl -n ate-system get secret session-id-jwt-pool >/dev/null 2>&1 && [ "$f" = --create-jwt-authority-pool-secret ] && continue
    kubectl -n podcertificate-controller-system get secret service-dns-ca-pool >/dev/null 2>&1 && [ "$f" = --create-podcertificate-controller-cas ] && continue
    bash hack/install-ate.sh "$f" 2>&1 | grep -iE "created|error" | tail -2
  done
  kubectl -n ate-system get secret valkey-ca-certs >/dev/null 2>&1 || bash hack/install-ate.sh --create-valkey-ca-certs-secret 2>&1 | grep -iE "created|error" | tail -1 )
helm upgrade --install substrate-crds oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds --version $SUBSTRATE -n ate-system --wait >/dev/null
helm upgrade --install substrate oci://ghcr.io/kagent-dev/substrate/helm/substrate --version $SUBSTRATE -n ate-system --set auth.mode=mtls >/dev/null
kubectl -n podcertificate-controller-system rollout status deploy --timeout=180s >/dev/null 2>&1 || warn "podcertificate controller not up yet"
kubectl -n ate-system rollout status deploy --timeout="$(tmo 600s 300s)" >/dev/null 2>&1 || { warn "substrate pods not all up yet:"; kubectl -n ate-system get pods --no-headers | grep -vE 'Running|Completed' | sed 's/^/      /'; }
# now kagent may own a WorkerPool
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version $KAGENT -n kagent -f "$M/kagent-values.yaml" \
  --set substrateWorkerPool.ateomImage="ghcr.io/kagent-dev/substrate/ateom-gvisor:v$SUBSTRATE" --wait --timeout "$(tmo 15m 6m)" >/dev/null
kubectl -n kagent get workerpools.ate.dev 2>/dev/null || warn "no WorkerPool yet"
ok "Substrate installed; kagent substrate integration on"

step "what the learner sees"
kubectl get agents.kagent.dev -A
kubectl -n openshell get pods --no-headers | awk '{print "  openshell", $1, $3}'
