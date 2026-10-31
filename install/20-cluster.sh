#!/usr/bin/env bash
# Makes the kind cluster one that bnk-deploy's preflight accepts, the way bnk-deploy's own e2e-kind CI does.
# Calico is already in (10-fabric.sh installs it while containerlab waits for Ready). Here: control plane
# untainted (22.55 vCPU of requests need every node), kubelets restarted so they advertise the host's hugepages,
# and the TMM node labelled. kind's "standard" StorageClass (local-path) is what the lab environment expects.
source "$(dirname "$0")/lib/common.sh"
kubectl cluster-info >/dev/null || fail "no cluster; run 10-fabric.sh first"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

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

step "CNI plugins into every node (kind ships only host-local, loopback, portmap, ptp; TMM's legs are macvlan)"
CNI_PLUGINS=v1.9.1
T=$(mktemp -d)
curl -fsSL -o "$T/cni.tgz" "https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS/cni-plugins-linux-amd64-$CNI_PLUGINS.tgz"
curl -fsSL -o "$T/cni.tgz.sha256" "https://github.com/containernetworking/plugins/releases/download/$CNI_PLUGINS/cni-plugins-linux-amd64-$CNI_PLUGINS.tgz.sha256"
( cd "$T" && sed 's/  .*/  cni.tgz/' cni.tgz.sha256 | sha256sum -c - >/dev/null ) || fail "CNI plugins tarball checksum mismatch"
mkdir -p "$T/bin" && tar -xzf "$T/cni.tgz" -C "$T/bin"
for n in bnk-control-plane bnk-worker bnk-worker2; do
  # add what the node lacks; the four kind ships stay as they are
  for b in "$T"/bin/*; do docker exec "$n" test -x "/opt/cni/bin/$(basename "$b")" 2>/dev/null || docker cp "$b" "$n:/opt/cni/bin/"; done
  ok "$n: $(docker exec "$n" ls /opt/cni/bin | wc -l) CNI plugins ($(docker exec "$n" test -x /opt/cni/bin/macvlan && echo macvlan present))"
done
rm -rf "$T"

step "node roles"
kubectl label node bnk-worker app=f5-tmm --overwrite >/dev/null
kubectl label node bnk-worker2 workload=ai --overwrite >/dev/null
kubectl get nodes -L app,workload
kubectl get sc
