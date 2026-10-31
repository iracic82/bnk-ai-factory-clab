#!/usr/bin/env bash
# Makes the kind cluster one that bnk-deploy's preflight accepts, the way bnk-deploy's own e2e-kind CI does:
# Calico through the Tigera operator (FLO's preflight has to recognise the CNI), control plane untainted
# (22.55 vCPU of requests need every node), kubelets restarted so they advertise the host's hugepages, and the
# TMM node labelled. kind's "standard" StorageClass (local-path) is what the lab environment expects.
source "$(dirname "$0")/lib/common.sh"
kubectl cluster-info >/dev/null || fail "no cluster; run 10-fabric.sh first"

step "Calico $CALICO_VERSION"
kubectl get ns tigera-operator >/dev/null 2>&1 || \
  kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s
until kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; do sleep 2; done
kubectl apply -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata: {name: default}
spec:
  calicoNetwork:
    ipPools:
    - {cidr: 192.168.0.0/16, encapsulation: VXLANCrossSubnet, natOutgoing: Enabled, nodeSelector: all()}
    # the kind docker network, not the fabric link: TMM owns eth1
    nodeAddressAutodetectionV4: {interface: eth0}
EOF
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
ok "nodes Ready, control plane schedulable"

step "hugepages on every node"
hp=$(awk '/HugePages_Total/{print $2}' /proc/meminfo)
[ "$hp" -ge "$NR_HUGEPAGES" ] || fail "host has $hp hugepages; run 00-host-prep.sh"
for n in bnk-control-plane bnk-worker bnk-worker2; do
  docker exec "$n" systemctl restart kubelet
done
for n in bnk-control-plane bnk-worker bnk-worker2; do
  until [ "$(kubectl get node "$n" -o jsonpath='{.status.allocatable.hugepages-2Mi}' 2>/dev/null)" != "0" ] && \
        [ -n "$(kubectl get node "$n" -o jsonpath='{.status.allocatable.hugepages-2Mi}' 2>/dev/null)" ]; do sleep 3; done
  ok "$n hugepages-2Mi $(kubectl get node "$n" -o jsonpath='{.status.allocatable.hugepages-2Mi}')"
done

step "node roles"
kubectl label node bnk-worker app=f5-tmm --overwrite >/dev/null
kubectl label node bnk-worker2 workload=ai --overwrite >/dev/null
kubectl get nodes -L app,workload
kubectl get sc
