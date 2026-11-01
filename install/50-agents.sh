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
KAGENT=0.10.4; SUBSTRATE=0.0.9; OPENSHELL=0.1.5; SANDBOX=v1.0.7
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
kubectl -n f5-bnk wait --for=condition=Programmed gateway/agents-gw --timeout=240s >/dev/null && ok "agents gateway on 172.16.100.14" || warn "gateway agents-gw not Programmed"
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
  # a long-running sandbox per tenant; chapter 8 shows its policy, chapter 12 shows it cannot reach the webhook.
  # python:3.12-slim (in the image cache since chapter 3 uses it): OpenShell's default image is a bare Ubuntu with
  # no curl, wget or python, so nothing in it could open a connection and chapter 8 saw "command not found"
  # instead of a policy decision (play 5, 2026-11-01). The provider profile lists python3 among its binaries.
  openshell sandbox list 2>/dev/null | grep -q "^$ns-agent\b" || \
    openshell sandbox create --name "$ns-agent" --from python:3.12-slim --provider "f5-aigw-$ns" --env "OPENAI_BASE_URL=http://$host/v1" --no-tty -- sleep infinity >/dev/null 2>&1 &
done
for _ in $(seq 1 "$(tmo 60 12)"); do [ "$(openshell sandbox list 2>/dev/null | grep -c Ready)" -ge 3 ] && break; sleep 5; done
openshell sandbox list 2>/dev/null || warn "openshell sandbox list failed"

step "Agent Substrate $SUBSTRATE (JWT mode: the mode kagent's controller speaks)"
# 0.0.9 is the Substrate the kagent 0.10.4 chart bundles (charts/substrate) and its Go module pins. Both charts default
# to auth.mode=jwt: the API server's certificate and session-signing pools are generated by the chart, Valkey runs in
# plaintext, and clients authenticate with a projected ServiceAccount token. kagent's controller mounts exactly that
# token and nothing else (templates/controller-deployment.yaml), so Substrate in mtls mode, which demands a client
# certificate, can never be dialled by it: "dial ate-api: context deadline exceeded" for good (play 5, 2026-11-01).
# The issuer must be the cluster's own (kind: https://kubernetes.default.svc.cluster.local); read it, do not assume it.
# 0.0.11 was tried first: its router's agentgateway reads a servicedns credential bundle the chart never writes.
ISS=$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])' 2>/dev/null)
[ -n "$ISS" ] || fail "could not read the cluster's service-account issuer from /.well-known/openid-configuration"
echo "   service-account issuer: $ISS"
helm upgrade --install substrate-crds oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds --version $SUBSTRATE -n ate-system --create-namespace --wait >/dev/null
helm upgrade --install substrate oci://ghcr.io/kagent-dev/substrate/helm/substrate --version $SUBSTRATE -n ate-system \
  --set auth.jwt.issuer="$ISS" --wait --timeout "$(tmo 10m 5m)" >/dev/null \
  || { warn "substrate chart did not become ready:"; kubectl -n ate-system get pods --no-headers | grep -vE 'Running|Completed' | sed 's/^/      /'; }
kubectl -n ate-system get pods --no-headers | awk '{printf "   %-42s %s\n", $1, $3}'
# now kagent may own a WorkerPool. controller.substrate.ateApiInsecure=true sits in kagent-values.yaml: the kagent chart
# has no way to mount Substrate's generated CA (ateapi-ca), so the controller cannot verify the self-signed server
# certificate and its dial times out the same way; the token still authenticates it.
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version $KAGENT -n kagent -f "$M/kagent-values.yaml" \
  --set substrateWorkerPool.ateomImage="ghcr.io/kagent-dev/substrate/ateom-gvisor:v$SUBSTRATE" --wait --timeout "$(tmo 15m 6m)" >/dev/null
kubectl -n kagent get workerpools.ate.dev 2>/dev/null || warn "no WorkerPool yet"
P=$(kubectl -n kagent get pods -o name | grep kagent-controller | tail -1)
kubectl -n kagent logs "$P" --tail=400 2>/dev/null | grep -q '"controller":"sandboxagent"' \
  && ok "kagent controller reaches Substrate (sandboxagent controller started)" \
  || warn "kagent controller has not started its sandboxagent controller yet: $(kubectl -n kagent logs "$P" --tail=400 2>/dev/null | grep -iE 'substrate' | grep -viE 'Request completed' | tail -1 | cut -c1-160)"
ok "Substrate installed; kagent substrate integration on"

step "what the learner sees"
kubectl get agents.kagent.dev -A
kubectl -n openshell get pods --no-headers | awk '{print "  openshell", $1, $3}'
