#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
cd /root/ai4
kubectl create ns kagent --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n kagent create secret generic kagent-openai --from-literal=OPENAI_API_KEY="$(tr -d " \n\r" < /root/ai4/kagent-virtual-key)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install kagent-crds ./charts/kagent-crds -n kagent --wait >/dev/null
helm upgrade --install kagent ./charts/kagent -n kagent -f 20-kagent-values.yaml --wait --timeout 15m >/dev/null
kubectl -n kagent get pods,modelconfig,remotemcpserver
