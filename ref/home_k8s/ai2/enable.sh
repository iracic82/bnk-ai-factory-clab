#!/usr/bin/env bash
# Turn the AI Gateway on in the installed BNK, following docs/source-guide/deploy.md, and check every
# condition the guide names. Run on the control node after platform/cluster/setup-cluster.sh.
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
LAB_ROOT="${LAB_ROOT:-/root/lab}"
step() { echo; echo "### $*"; }
fail() { echo; echo "SETUP FAILED: $*" >&2; exit 1; }

NS=$(kubectl get cneinstance -A -o jsonpath='{.items[0].metadata.namespace}')
CNE=$(kubectl get cneinstance -A -o jsonpath='{.items[0].metadata.name}')
[ -n "$NS" ] && [ -n "$CNE" ] || fail "no CNEInstance found"
printf 'export BNK_NAMESPACE=%s\nexport CNE_INSTANCE=%s\n' "$NS" "$CNE" > /etc/profile.d/aigw.sh
echo "CNEInstance ${NS}/${CNE}"

step "the release manifest must carry the AI Gateway images"
# 2.4.1 lists images/f5-aigateway-ui and images/clickhouse-server; 2.4.0 has neither (spike/evidence/).
kubectl get cnemanifest -A -o yaml | grep -E 'f5-aigateway-ui|clickhouse-server' -A1 \
  || fail "the installed CNEManifest has no f5-aigateway-ui / clickhouse-server, so this is not a 2.4.1 bundle"

step "session store in sentinel mode (else the operator silently skips the AI Gateway)"
clustered=$(kubectl -n "$NS" get cneinstance "$CNE" -o jsonpath='{.spec.sessionStore.clustered}')
disabled=$(kubectl -n "$NS" get cneinstance "$CNE" -o jsonpath='{.metadata.annotations.cneinstance\.k8s\.f5\.com/disable-session-state}')
echo "sessionStore.clustered='${clustered}' disable-session-state='${disabled}'"
[ "$clustered" != "true" ] && [ "$disabled" != "true" ] || fail "session store is not in sentinel mode"

step "merge patch from the guide, server dry run first"
kubectl explain cneinstance.spec.aiGateway.aiMetrics >/dev/null \
  || fail "the CNEInstance schema has no spec.aiGateway.aiMetrics (lifecycle-operator CRDs too old)"
PATCH="$LAB_ROOT/docs/source-guide/examples/enable-aigateway.json"
kubectl -n "$NS" patch cneinstance "$CNE" --type=merge --patch-file="$PATCH" --dry-run=server --warnings-as-errors -o name
kubectl -n "$NS" patch cneinstance "$CNE" --type=merge --patch-file="$PATCH"

step "AIGateway Reconciled (the guide: False/Waiting while logging or ClickHouse is not ready)"
r=""
for i in $(seq 1 90); do
  r=$(kubectl -n "$NS" get aigateways.k8s.f5.com -o jsonpath='{.items[0].status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null || true)
  [ "$r" = "True" ] && { echo "Reconciled after $((i*20))s"; break; }
  sleep 20
done
kubectl -n "$NS" get aigateways.k8s.f5.com -o yaml | sed -n '/^  status:/,$p'
[ "$r" = "True" ] || fail "AIGateway not Reconciled after 30 minutes"

step "the checks from deploy.md"
kubectl -n "$NS" get cnecontrollers.k8s.f5.com -o jsonpath='{range .items[*].status.conditions[?(@.type=="AIGatewayDNSResolverReady")]}AIGatewayDNSResolverReady={.status} {.reason}{"\n"}{end}'
kubectl -n "$NS" get svc f5-cne-controller-api f5-aigateway-console
kubectl -n "$NS" get f5-big-dns-caches.k8s.f5net.com aigw-dns-resolver
kubectl -n "$NS" get f5-big-log-hslpubs.k8s.f5net.com aigw-hslpub
kubectl get pvc -A | grep -i clickhouse || echo "no ClickHouse PVC listed"

step "the controller may create and delete AppPolicies (REST route creation needs both)"
# AIGateway Reconciled does not mean the AppPolicy CRD and the operator's grant are in place yet: on
# 2026-10-21 one boot read "yes/yes" and the next, from the same commit, read "the server doesn't have a
# resource type 'apppolicies'" 20 s after Reconciled. Wait for the CRD, then for both grants, and fail
# only if they never arrive. (kubectl auth can-i exits 1 on "no", so it cannot run bare under set -e.)
# kubectl wait errors out at once on a CRD that does not exist yet, so poll for it first.
for _ in $(seq 1 120); do kubectl get crd apppolicies.gateway.k8s.f5.com >/dev/null 2>&1 && break; sleep 5; done
kubectl wait --for=condition=Established crd/apppolicies.gateway.k8s.f5.com --timeout=60s \
  || fail "the AppPolicy CRD (apppolicies.gateway.k8s.f5.com) never registered"
SA=$(kubectl -n "$NS" get deployment f5-cne-controller -o jsonpath='{.spec.template.spec.serviceAccountName}')
for verb in create delete; do
  ok=""
  for _ in $(seq 1 60); do
    [ "$(kubectl auth can-i "$verb" apppolicies.gateway.k8s.f5.com --as="system:serviceaccount:${NS}:${SA}" -n "$NS" 2>/dev/null || true)" = "yes" ] && { ok=1; break; }
    sleep 5
  done
  echo "$verb apppolicies: ${ok:+yes}${ok:-no}"
  [ -n "$ok" ] || fail "the controller (${SA}) still may not ${verb} AppPolicies after 5 min; REST route creation would fail"
done

step "console on :3000 and management API on :18443, forwarded to their Service ClusterIPs"
# Not kubectl port-forward: it binds to ONE pod when it starts, and when that pod moves it drops the next
# request and exits ("lost connection to pod"), so every call in the 3 s restart gap is refused (seen live
# 2026-10-21 after the controller moved to the control node). socat targets the Service ClusterIP, which
# kube-proxy on this node maps to whichever pod is current, so rollouts and placement changes are invisible.
# The console listens on 0.0.0.0 so the Instruqt tab (which reaches the VM, not localhost) can use it; the
# management API stays on 127.0.0.1, the guide's own local URL.
command -v socat >/dev/null || apt-get install -y -qq socat >/dev/null || fail "could not install socat"
fwd_unit() { # name svc listen-address listen-port
  local ip port
  ip="$(kubectl -n "$NS" get svc "$2" -o jsonpath='{.spec.clusterIP}')" || fail "no Service $2"
  port="$(kubectl -n "$NS" get svc "$2" -o jsonpath='{.spec.ports[0].port}')"
  [ -n "$ip" ] && [ -n "$port" ] || fail "Service $2 has no ClusterIP/port"
  systemctl disable --now "aigw-pf-$1" >/dev/null 2>&1 || true
  cat > "/etc/systemd/system/aigw-pf-$1.service" <<EOF
[Unit]
Description=AI Gateway $1: ${3}:${4} -> Service ${2} (${ip}:${port})
After=network-online.target
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${4},bind=${3},reuseaddr,fork TCP:${ip}:${port}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
}
fwd_unit console f5-aigateway-console 0.0.0.0 3000
fwd_unit api f5-cne-controller-api 127.0.0.1 18443
systemctl daemon-reload
systemctl enable aigw-pf-console aigw-pf-api >/dev/null
systemctl restart aigw-pf-console aigw-pf-api
for _ in $(seq 1 30); do curl -fsS -o /dev/null http://127.0.0.1:18443/api/v1/admin/health && break; sleep 2; done
curl --fail-with-body -sS http://127.0.0.1:18443/api/v1/admin/health; echo
curl --fail-with-body -sS http://127.0.0.1:18443/api/v1/admin/ready; echo
# /admin/version needs a login (the API reference lists only health and ready as open). The token stays
# in this shell and is never printed.
TOKEN=$(jq -n \
  --arg u "$(kubectl -n "$NS" get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)" \
  --arg p "$(kubectl -n "$NS" get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)" \
  '{username:$u,password:$p}' |
  curl -sS --fail-with-body http://127.0.0.1:18443/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @- |
  jq -er '.access_token') || fail "platform admin login to the management API failed"
curl -sS --fail-with-body http://127.0.0.1:18443/api/v1/admin/version -H "Authorization: Bearer $TOKEN"; echo

step "request history must be readable (the controller checks ClickHouse only once, at start)"
# F5 2.4.1 bug, seen on 2026-10-21: the controller started at 09:23:53, pinged ClickHouse at 09:24:16 and
# got "connection refused" ("observability ClickHouse not reachable; the analytical shapes report
# unavailable"), ClickHouse went Ready at 09:24:26, and the controller never pinged again, so every
# observability view stayed "no store configured". On a fresh install the controller always starts
# first. Wait for ClickHouse, then restart the controller once if it still reports the store
# unavailable. Fail if it is still unavailable after that.
unset TOKEN
kubectl -n "$NS" wait --for=condition=Ready pod/f5-aigateway-clickhouse-0 --timeout=600s \
  || fail "ClickHouse (f5-aigateway-clickhouse-0) never became Ready"
# Fresh boot 2026-10-21 (d2ad614): the check below used to read "no warning in the controller log yet" as
# success. It ran before the controller's one-time ping (24 s after start), which then failed: the Service
# briefly pointed at the schema Job's pod, not ClickHouse. Absence of a warning proves nothing before the
# ping. So: wait for ClickHouse Ready AND its schema Job complete, then restart the controller once,
# unconditionally, and require the ping window to pass without the warning in the NEW pod.
CH_DOWN='observability ClickHouse not reachable'
JOB=$(kubectl -n "$NS" get job -o name | grep clickhouse-schema | head -1)
[ -n "$JOB" ] && { kubectl -n "$NS" wait --for=condition=Complete "$JOB" --timeout=600s || fail "ClickHouse schema job did not complete"; }
for _ in $(seq 1 60); do   # the Service must point only at ClickHouse itself
  eps=$(kubectl -n "$NS" get endpoints f5-aigateway-clickhouse -o jsonpath='{.subsets[*].addresses[*].targetRef.name}')
  [ "$eps" = f5-aigateway-clickhouse-0 ] && break; sleep 5
done
echo "  ClickHouse Service endpoints: ${eps:-none}"
ctrl_pod() {
  kubectl -n "$NS" get pod -l app=f5-cne-controller --field-selector=status.phase=Running \
    --sort-by=.metadata.creationTimestamp -o name | tail -1
}
kubectl -n "$NS" rollout restart deploy/f5-cne-controller
kubectl -n "$NS" rollout status deploy/f5-cne-controller --timeout=300s || fail "f5-cne-controller did not come back"
for _ in $(seq 1 60); do
  [ "$(kubectl -n "$NS" get pod -l app=f5-cne-controller --no-headers 2>/dev/null | wc -l)" -le 1 ] && break; sleep 5
done
for _ in $(seq 1 60); do curl -fsS -o /dev/null http://127.0.0.1:18443/api/v1/admin/ready && break; sleep 3; done
curl -fsS -o /dev/null http://127.0.0.1:18443/api/v1/admin/ready || fail "the management API did not come back after the controller restart"
P=$(ctrl_pod); started=$(kubectl -n "$NS" get "$P" -o jsonpath='{.status.startTime}')
sleep 60   # the one-time ping runs about 24 s after start; wait past it before reading the verdict
kubectl -n "$NS" logs "$P" -c f5-cne-controller 2>/dev/null | grep -q "$CH_DOWN" \
  && fail "the controller ($P, started $started) still cannot reach ClickHouse; see its log for '${CH_DOWN}'"
echo "  controller $P (started $started) reached ClickHouse: no '${CH_DOWN}' after the ping window"
curl -fsS -o /dev/null -w 'console: HTTP %{http_code}\n' http://127.0.0.1:3000/ || fail "the console does not answer on :3000"

step "learner shell: management API URL"
printf 'export API_URL=http://127.0.0.1:18443\n' >> /etc/profile.d/aigw.sh
# Instruqt terminal tabs are not login shells, so /etc/profile.d is not read there and $BNK_NAMESPACE
# arrived empty on 2026-10-21 ("flags cannot be placed before plugin name: -n"). Load it from .bashrc.
grep -q 'profile.d/aigw.sh' /root/.bashrc 2>/dev/null || echo '. /etc/profile.d/aigw.sh' >> /root/.bashrc
step "learner tools: aigw-api helper, Python clients, INFERENCE_URL"
install -m 755 "$(dirname "${BASH_SOURCE[0]}")/bin/aigw-api" "$(dirname "${BASH_SOURCE[0]}")/bin/aigw-creds" /usr/local/bin/
printf 'export INFERENCE_URL=http://172.16.201.10\n' >> /etc/profile.d/aigw.sh
# Clients the challenges use: the OpenAI SDK (apps talk to the gateway), the Anthropic SDK (the same
# gateway in Anthropic's dialect) and AWS's Bedrock token generator (mints the short-term Bedrock API key
# the gateway uses upstream). Pinned; a venv so the system Python stays untouched.
# `import venv` succeeds on Ubuntu without python3.X-venv; creating a venv needs ensurepip, which is in that
# package (fresh boot 2026-10-21 failed here). Test ensurepip and install the version-matched package.
if ! python3 -c 'import ensurepip' 2>/dev/null; then
  PYV=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
  apt-get install -y -qq "python${PYV}-venv" >/dev/null || apt-get install -y -qq python3-venv >/dev/null \
    || fail "could not install python${PYV}-venv"
fi
rm -rf /opt/aigw-venv
python3 -m venv /opt/aigw-venv || fail "could not create /opt/aigw-venv"
/opt/aigw-venv/bin/pip install -q openai==3.26.0 anthropic==1.11.0 aws-bedrock-token-generator==1.1.0 \
  || fail "could not install the Python clients"
# A wrapper, not a symlink: a venv's python finds pyvenv.cfg next to the path it was started from, so a
# symlink in /usr/local/bin runs as the system python without the venv's packages (seen live 2026-10-21).
printf '#!/bin/sh\nexec /opt/aigw-venv/bin/python "$@"\n' > /usr/local/bin/aigw-python && chmod 755 /usr/local/bin/aigw-python
aigw-api GET /admin/version >/dev/null || fail "aigw-api cannot reach the management API"
echo "AI Gateway enabled"
