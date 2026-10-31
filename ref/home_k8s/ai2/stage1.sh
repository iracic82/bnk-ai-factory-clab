#!/usr/bin/env bash
# Stage 1: GAIE CRDs, EPP namespace, AI Gateway (Polaris console) enable.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
cd /root/ai2
echo "### GAIE CRDs v1.4.0"
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.4.0/manifests.yaml >/dev/null
kubectl get crd inferencepools.inference.networking.k8s.io -o name
echo "### EPP namespace aigw-models + pull secrets"
kubectl create namespace aigw-models --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace aigw-models --overwrite aigw.lab/engine=dynamo >/dev/null
for n in far-secret far-pull-secret; do
  kubectl -n default get secret far-secret -o json | jq --arg n $n 'del(.metadata|.namespace,.uid,.resourceVersion,.creationTimestamp,.ownerReferences,.managedFields)|.metadata.name=$n|.metadata.namespace="aigw-models"' | kubectl apply -f - >/dev/null
done
kubectl patch cneinstance bnk-eve --type=merge -p '{"spec":{"eppNamespaces":["aigw-models"]}}'
echo "### AI Gateway / Polaris (reference enable.sh, LAB_ROOT=/root/ai2)"
LAB_ROOT=/root/ai2 bash ./enable.sh
echo "STAGE1 DONE"
