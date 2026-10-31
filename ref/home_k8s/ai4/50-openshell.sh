#!/usr/bin/env bash
# NVIDIA OpenShell 0.1.5 gateway on Kubernetes + Agent Sandbox controller (kubernetes-sigs) v1.0.7.
# Calico enforces the NetworkPolicies OpenShell creates for sandbox pods.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
cd /root/ai4
[ -s agent-sandbox-v1.0.7.yaml ] || curl -sSfL -o agent-sandbox-v1.0.7.yaml \
  https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v1.0.7/sandbox.yaml
kubectl apply -f agent-sandbox-v1.0.7.yaml >/dev/null
kubectl -n agent-sandbox-system rollout status deploy --timeout=300s
kubectl create namespace openshell --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install openshell ./charts/helm-chart -n openshell --wait --timeout 10m >/dev/null
kubectl -n openshell rollout status statefulset/openshell --timeout=300s
kubectl -n openshell get pods,svc,secrets --no-headers
# CLI: official static musl build from the v0.1.5 release, checksum-verified
if ! command -v openshell >/dev/null; then
  R=https://github.com/NVIDIA/OpenShell/releases/download/v0.1.5
  T=$(mktemp -d); cd $T
  curl -sSfLO $R/openshell-x86_64-unknown-linux-musl.tar.gz -O $R/openshell-checksums-sha256.txt
  grep ' openshell-x86_64-unknown-linux-musl.tar.gz$' openshell-checksums-sha256.txt | sha256sum -c -
  tar xzf openshell-x86_64-unknown-linux-musl.tar.gz && install -m 0755 $(find . -type f -name openshell | head -1) /usr/local/bin/openshell
  cd /root/ai4; rm -rf $T
fi
openshell --version
