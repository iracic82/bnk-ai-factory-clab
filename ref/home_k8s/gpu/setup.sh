#!/usr/bin/env bash
# Fake H100s on w1/w2 plus the KAI Scheduler with one GPU queue per tenant. Runs from the workstation:
#   KUBECONFIG=~/.kube/bnk-eve.config install/gpu/setup.sh
set -euo pipefail
cd "$(dirname "$0")"
FGO=0.2.1 KAI=v0.18.6
for n in bnk-w1 bnk-w2; do kubectl label node $n run.ai/simulated-gpu-node-pool=h100 --overwrite; done
helm upgrade -i gpu-operator oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator --version $FGO \
  -n gpu-operator --create-namespace -f 10-fake-gpu-values.yaml --wait --timeout 5m
helm upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler --version $KAI \
  -n kai-scheduler --create-namespace -f 20-kai-values.yaml --wait --timeout 5m
# Helm only waits for the KAI operator; the operator then creates the scheduler, binder and queue webhook itself.
until kubectl -n kai-scheduler get deploy queue-controller >/dev/null 2>&1; do sleep 3; done
kubectl -n kai-scheduler rollout status deploy --timeout 5m
until kubectl apply -f 30-queues.yaml 2>/dev/null; do sleep 5; done
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
kubectl get queues.scheduling.run.ai
