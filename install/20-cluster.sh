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

step "a second leg for bnk-worker on the kind network (the parent for TMM's internal macvlan)"
# TMM's internal leg is a macvlan on the TMM node. A macvlan child cannot exchange packets with its parent's own
# address (the EVE lab needed a third NIC for the same reason, docs/topology.md there). With eth0 as the parent,
# bnk-worker itself, and every pod on it, would never reach TMM's internal self IP: no egress tunnel from that node,
# no route to the VIPs from it. So bnk-worker gets a second veth into the same docker bridge, eth2, with no address;
# the NAD internal-net (30-bnk.sh) uses it as the parent, and the node keeps talking through eth0 across the bridge.
BR="br-$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)"
ip link show "$BR" >/dev/null 2>&1 || fail "kind docker bridge $BR not found"
if ! docker exec bnk-worker ip link show eth2 >/dev/null 2>&1; then
  PID=$(docker inspect -f '{{.State.Pid}}' bnk-worker)
  sudo ip link del tmm-int0 2>/dev/null || true
  sudo ip link add tmm-int0 mtu 1500 type veth peer name eth2 mtu 1500 netns "$PID"
  sudo ip link set tmm-int0 master "$BR" up
  docker exec bnk-worker ip link set eth2 up
fi
ok "bnk-worker eth2 <-> $BR:tmm-int0 ($(docker exec bnk-worker cat /sys/class/net/eth2/operstate))"

step "an interface CSRC can see on every node (the tunnel endpoint for BNK egress)"
# BNK's CSRC daemonset reports each node's interfaces to the controller, and the controller picks the one whose
# address sits in TMM's internal VLAN subnet as that node's VXLAN endpoint. CSRC lists physical devices, vxlan
# devices and lo; it leaves veths out, and a kind node's eth0 is a veth. Found in play 6 (2026-11-01): CSRC reported
# only lo and vxlan.calico, the controller logged "Error finding interface on worker node: interface not found"
# and "Add:Vxlan Empty node data", and no tunnel was ever built. A macvlan child of eth0 with its own address in
# the kind subnet is reported (verified live: csrc0 in the report, vxlan100-102 built, LocalAddr = its address).
# Its traffic rides eth0 to the docker bridge like any other MAC, and TMM's internal self IP is a macvlan on
# another parent (bnk-worker eth2), so the two can talk even on the TMM node. Addresses .241-.243: above anything
# docker hands out on this network and below TMM's .250. Calico keeps eth0 (nodeAddressAutodetectionV4 in
# 10-fabric.sh), so this never becomes a node address.
KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Subnet}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/' | head -1)
KIND_NET3="$(echo "${KIND_SUBNET%/*}" | cut -d. -f1-3)"; KIND_PLEN="${KIND_SUBNET#*/}"
i=0
for n in bnk-control-plane bnk-worker bnk-worker2; do
  i=$((i+1)); a="$KIND_NET3.24$i/$KIND_PLEN"
  docker exec "$n" ip link show csrc0 >/dev/null 2>&1 || docker exec "$n" ip link add csrc0 link eth0 type macvlan mode bridge
  docker exec "$n" ip -4 addr show dev csrc0 | grep -q "inet $a " || docker exec "$n" ip addr add "$a" dev csrc0
  docker exec "$n" ip link set csrc0 up
  ok "$n csrc0 $(docker exec "$n" ip -br addr show csrc0 | awk '{print $3}') on eth0"
done

step "node roles"
kubectl label node bnk-worker app=f5-tmm --overwrite >/dev/null
kubectl label node bnk-worker2 workload=ai --overwrite >/dev/null
kubectl get nodes -L app,workload
kubectl get sc
