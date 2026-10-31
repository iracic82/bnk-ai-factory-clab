#!/usr/bin/env bash
# Stage 2: NVIDIA Dynamo platform (operator + NATS) + GPU-free mocker DGD (reference platform/models).
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
cd /root/ai2/models
sysctl -w fs.inotify.max_user_instances=1024 >/dev/null
grep -q max_user_instances.*1024 /etc/sysctl.d/99-bnk.conf || sed -i 's/fs.inotify.max_user_instances = 512/fs.inotify.max_user_instances = 1024/' /etc/sysctl.d/99-bnk.conf
helm upgrade --install dynamo-platform https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-1.5.1.tgz \
  -n dynamo-system --create-namespace --set global.nats.install=true --wait --timeout 15m >/dev/null
kubectl -n dynamo-system rollout status statefulset/dynamo-platform-nats --timeout=300s
kubectl apply -f nats-policy.yaml >/dev/null
kubectl create namespace aigw-models --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace aigw-models --overwrite aigw.lab/engine=dynamo >/dev/null
kubectl -n aigw-models create secret generic hf-token-secret --from-literal=HF_TOKEN= --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n aigw-models apply -f dgd.yaml
kubectl -n aigw-models wait dynamographdeployment/mocker --for=condition=Ready --timeout=1200s || true
kubectl -n aigw-models get pods -o wide --no-headers | awk '{print $1,$2,$3,$7}'
echo "STAGE2 DONE"
