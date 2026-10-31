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

step "kernel modules for the fabric (the FRR containers share the host kernel)"
# VRF, VXLAN, 802.1q and bridge devices are what the leaves and the border build. On the Instruqt VM (Ubuntu 24.04
# GCP kernel) 'ip link add ... type vrf' answered "Unknown device type" (bake of 2026-10-31): the vrf module ships
# in linux-modules-extra, which the cloud image does not install. Loaded now, listed for boot, and proven.
#
# The cloud image can also run a kernel ABI the archive has already dropped (the Instruqt VM ran 6.8.0-1015-gcp
# while noble-updates carried 1065 and later), so apt cannot install the package. Launchpad keeps every build:
# its API resolves the exact linux-modules-extra package for the running ABI and the .deb is installed from there.
modules_extra_from_launchpad() {
  local pkg="linux-modules-extra-$(uname -r)" api="https://api.launchpad.net/devel/ubuntu/+archive/primary" pub url deb
  pub=$(curl -fsS -m 60 "$api?ws.op=getPublishedBinaries&binary_name=$pkg&exact_match=true&distro_arch_series=https://api.launchpad.net/devel/ubuntu/noble/amd64" \
        | python3 -c 'import json,sys; e=json.load(sys.stdin)["entries"]; print(e[0]["self_link"] if e else "")')
  [ -n "$pub" ] || return 1
  url=$(curl -fsS -m 60 "$pub?ws.op=binaryFileUrls" | python3 -c 'import json,sys; u=json.load(sys.stdin); print(u[0] if u else "")')
  [ -n "$url" ] || return 1
  deb=$(mktemp -d)/$pkg.deb
  echo "      $pkg is not in the archive any more; fetching Ubuntu's build from Launchpad"
  curl -fsSL -m 600 -o "$deb" "$url" && sudo dpkg -i "$deb" >/dev/null && rm -f "$deb"
}
for m in vrf vxlan 8021q bridge; do
  if ! sudo modprobe "$m" 2>/dev/null; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || modules_extra_from_launchpad || true
    sudo modprobe "$m" || fail "kernel module $m is not available on this kernel ($(uname -r))"
  fi
done
printf 'vrf\nvxlan\n8021q\nbridge\n' | sudo tee /etc/modules-load.d/bnk-factory.conf >/dev/null
sudo ip link add bnk-vrf-probe type vrf table 4094 && sudo ip link del bnk-vrf-probe || fail "cannot create a VRF device"
ok "vrf, vxlan, 8021q, bridge loaded; VRF device creation works"

step "images"
for i in "$KIND_NODE_IMAGE" "$FRR_IMAGE" nicolaka/netshoot:v0.14; do
  docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i"; ok "$i"
done
