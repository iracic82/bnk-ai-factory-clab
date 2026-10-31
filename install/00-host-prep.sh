#!/usr/bin/env bash
# Host prerequisites. The one step that changes the host, so it is the one step that needs root.
# Everything after it runs as the docker user.
#
#   hugepages   TMM requests hugepages-2Mi and the operator keeps that request whatever you override. kind nodes
#               share the host kernel, so the pages are reserved here and the kubelets advertise them after a
#               restart (20-cluster.sh does the restart).
#   inotify     three kind nodes plus ~80 BNK pods exhaust the default 128 instances / 8192 watches; the symptom
#               is pods stuck ContainerCreating with "too many open files".
#   fs.aio      TMM uses async io; the default 65536 contexts run out on a busy node.
source "$(dirname "$0")/lib/common.sh"

step "tools"
for t in docker kind containerlab kubectl helm python3 jq; do need "$t"; ok "$t $(command -v "$t")"; done
docker info >/dev/null 2>&1 || fail "docker is not reachable for $(id -un)"
[ "$(nproc)" -ge 24 ] || warn "$(nproc) vCPU; BNK requests 22.55 and TMM alone 4.6, expect Pending pods below 24"
[ "$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)" -ge 48 ] || warn "less than 48 GB RAM"

step "kernel settings (sudo)"
SYSCTL=/etc/sysctl.d/90-bnk-factory.conf
sudo tee "$SYSCTL" >/dev/null <<EOF
vm.nr_hugepages = ${NR_HUGEPAGES}
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
fs.aio-max-nr = 1048576
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sudo sysctl -q -p "$SYSCTL"
hp=$(awk '/HugePages_Total/{print $2}' /proc/meminfo)
[ "$hp" -ge "$NR_HUGEPAGES" ] || fail "asked for $NR_HUGEPAGES hugepages, got $hp (fragmented memory; drop caches or reboot)"
ok "hugepages $hp x 2 Mi, inotify and aio raised"

step "images"
for i in "$KIND_NODE_IMAGE" "$FRR_IMAGE" nicolaka/netshoot:v0.14; do
  docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i"; ok "$i"
done
