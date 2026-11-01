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

step "a tenant leg on every node: the underlay of BNK's egress tunnels, one VLAN per tenant VRF"
# BNK's CSRC daemonset reports each node's interfaces to the controller, and the controller picks, per F5SPKEgress,
# the node interface whose address sits in the subnet of the TMM VLAN the egress names (tmmInterfaceName). Two facts
# of this build shape what that interface has to be (play 6, 2026-11-01, each verified live):
#  - CSRC lists physical devices, vlan and macvlan devices, vxlan devices and lo. It leaves veths out, and a kind
#    node's eth0 is a veth: with nothing else the controller logged "Error finding interface on worker node" and
#    built no tunnel. F5's own BNK-on-kind lab gives the nodes docker macvlan legs for the same reason.
#  - The egress tunnel of a tenant must sit entirely in that tenant's VRF. The controller programs the tunnel's
#    remote endpoints in the VRF of the F5SPKEgress, so an underlay in route domain 0 (TMM's internal VLAN) leaves
#    TMM looking the nodes up in the tenant VRF, whose only route is the default towards the fabric. On EVE the
#    fabric happened to route back to the node network; the kind network is private to this VM. So each tenant
#    gets its own leg: a tagged VLAN on TMM's 1.2 inside the tenant VRF (manifests/bnk/10-network.yaml, int-a/b/c,
#    tags 201-203, self IP .250), and on every node a VLAN sub-interface of eth0 with the matching tag and .241-.243.
#    The tags ride eth0 and the docker bridge like any frame and reach TMM's 1.2 through bnk-worker's eth2.
# Names must not contain "eth0": Calico's node interface setting is the regular expression eth0 (10-fabric.sh), and
# an eth0.203 made Calico move its own VXLAN endpoint onto the tenant leg (play 6).
KIND_PLEN=24
i=0
for n in bnk-control-plane bnk-worker bnk-worker2; do
  i=$((i+1))
  for t in a:201:1 b:202:2 c:203:3; do
    leg="int-${t%%:*}"; tag=$(echo "$t" | cut -d: -f2); a="10.249.$(echo "$t" | cut -d: -f3).24$i/$KIND_PLEN"
    docker exec "$n" ip link show "$leg" >/dev/null 2>&1 || docker exec "$n" ip link add "$leg" link eth0 type vlan id "$tag"
    docker exec "$n" ip -4 addr show dev "$leg" | grep -q "inet $a " || docker exec "$n" ip addr add "$a" dev "$leg"
    docker exec "$n" ip link set "$leg" up
  done
  ok "$n $(docker exec "$n" ip -br addr show type vlan | awk '{printf "%s %s  ", $1, $3}')"
done

step "checksum offload off on the egress tunnels (the F5 BNK-on-kind lab's hack, kept current by a watcher per node)"
# A pod's TCP checksum is left for hardware to fill, and on a veth nothing ever fills it. The kernel and Calico do not
# care, but TMM validates the checksum of what comes out of the tunnel and drops the SYN after the egress listener
# has already matched it: no counter, no log, 14 connections and no server side (play 6). F5's BNK-on-kind lab turns
# tx-checksum-ip-generic off on the egress vxlan devices after creating the F5SPKEgress objects. CSRC recreates those
# devices whenever an egress is declared again (chapter 12 does that), and the macvlan and vlan legs report the
# feature as fixed, so a small watcher per node keeps every CSRC vxlan device at checksum-off. It runs in the node's
# network namespace from the netshoot image the lab already has (the client container), with NET_ADMIN only.
for n in bnk-control-plane bnk-worker bnk-worker2; do
  docker rm -f "csum-$n" >/dev/null 2>&1 || true
  docker run -d --name "csum-$n" --restart unless-stopped --net "container:$n" --cap-add NET_ADMIN nicolaka/netshoot:v0.14 sh -c '
    while true; do
      for v in $(ip -br link show type vxlan 2>/dev/null | grep -v calico | cut -d@ -f1 | awk "{print \$1}"); do
        ethtool -k "$v" 2>/dev/null | grep -q "tx-checksum-ip-generic: on" && ethtool -K "$v" tx-checksum-ip-generic off >/dev/null 2>&1 && echo "$(date -u +%FT%TZ) $v tx-checksum-ip-generic off"
      done
      sleep 2
    done' >/dev/null
  ok "csum-$n watching $n for CSRC vxlan devices"
done

step "node roles"
kubectl label node bnk-worker app=f5-tmm --overwrite >/dev/null
kubectl label node bnk-worker2 workload=ai --overwrite >/dev/null
kubectl get nodes -L app,workload
kubectl get sc
