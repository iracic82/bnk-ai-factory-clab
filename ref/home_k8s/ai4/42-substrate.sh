#!/usr/bin/env bash
# Agent Substrate v0.0.11 = the release that matches kagent 0.10.4 (WorkerPool spec.ateomImage + ActorTemplate env valueFrom).
# Newer releases (0.0.12+) dropped env valueFrom, 0.0.22+ renamed ateomImage -> workerImage; kagent 0.10.4 needs both.
# Needs 00-feature-gates.sh first. CA pools come from the upstream installer (kubectl-ate via `go run`, Go in /usr/local/go).
set -uo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=auto
V=0.0.11; cd /root/ai4
kubectl -n kagent delete sandboxagent --all --ignore-not-found >/dev/null
kubectl -n kagent delete workerpool --all --ignore-not-found >/dev/null
helm -n ate-system uninstall substrate >/dev/null 2>&1; helm -n ate-system uninstall substrate-crds >/dev/null 2>&1
kubectl delete ns podcertificate-controller-system --ignore-not-found --wait=true >/dev/null
kubectl -n ate-system delete secret,cm,pvc --all >/dev/null 2>&1
rm -rf charts/substrate charts/substrate-crds
helm pull oci://ghcr.io/kagent-dev/substrate/helm/substrate-crds --version $V --untar -d charts >/dev/null
helm pull oci://ghcr.io/kagent-dev/substrate/helm/substrate --version $V --untar -d charts >/dev/null
helm upgrade --install substrate-crds ./charts/substrate-crds -n ate-system --create-namespace --wait >/dev/null && echo "crds $V"
helm upgrade --install substrate ./charts/substrate -n ate-system --set auth.mode=mtls >/dev/null && echo "chart $V"
rm -rf src-substrate && mkdir src-substrate
curl -sSfL https://github.com/kagent-dev/substrate/archive/refs/tags/v$V.tar.gz | tar -xz -C src-substrate --strip-components=1
cd src-substrate && git init -q .
for f in --create-podcertificate-controller-cas --create-actor-id-ca-pool-secret --create-jwt-authority-pool-secret --create-valkey-ca-certs-secret; do
  bash hack/install-ate.sh $f 2>&1 | grep -iE "created|error" | tail -2
done
cd ..; go clean -cache -modcache; rm -rf /root/.cache/go-build /root/go src-substrate
kubectl -n podcertificate-controller-system delete pod --all >/dev/null; kubectl -n ate-system delete pod --all >/dev/null
