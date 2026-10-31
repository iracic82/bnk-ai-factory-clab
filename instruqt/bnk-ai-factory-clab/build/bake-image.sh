#!/usr/bin/env bash
# Bakes the custom VM image the track boots from. Run once on an Instruqt custom-image VM (Ubuntu 24.04, 32 vCPU,
# 100 GB disk), then run finalise-image.sh, stop the VM and save it from the Instruqt UI as f5/aibnk.
#
# What it bakes: the tooling (docker, kind, containerlab, kubectl, helm), the kernel settings, and the registry
# mirrors with every image the lab pulls. The way to fill the mirrors without maintaining a list is to run the
# real install once through them; finalise-image.sh then removes the cluster, the fabric and every secret, and
# keeps /var/lib/bnk-mirrors. The image never carries a cluster: containerlab and kind build it at track start.
#
#   FAR_PULL_B64="$(cat cne_pull_64.json)" BNK_LICENSE_JWT="$(cat license.jwt)" GH_READ_TOKEN=... bash bake-image.sh
#
# BAKE_FAST=1 caps every long wait (BNK Available, Polaris Reconciled, mocker Ready, ...): the image needs the image
# pulls, not the Ready states, and the harvest step caches whatever any pod references. About half the time. Leave it
# unset when the bake should also be the full test of the lab.
#
# Run it from a copy outside the clone (finalise deletes the clone).
set -euo pipefail
exec > >(tee -a /var/log/bake-image.log) 2>&1
fail() { echo; echo "FAILED: $*" >&2; exit 1; }
step() { echo; echo "### $(date -u +%H:%M:%S) $*"; }
for s in FAR_PULL_B64 BNK_LICENSE_JWT GH_READ_TOKEN; do [ -n "${!s:-}" ] || fail "$s is not set"; done
[ "${BAKE_FAST:-0}" = 1 ] && export LAB_FAST=1 && echo "BAKE_FAST: long waits capped; the harvest step does the caching"

KIND_VERSION=v0.30.0
CLAB_VERSION=0.75.0
HELM_VERSION=v3.19.0
KUBECTL_VERSION=v1.30.13
LAB_ROOT=/root/lab; SECRETS_DIR=/root/.bnk

step "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get install -y -q ca-certificates curl git jq make python3 python3-yaml openssl iproute2 bridge-utils tcpdump >/dev/null
step "docker"
command -v docker >/dev/null || { curl -fsSL https://get.docker.com | sh >/dev/null; }
systemctl enable --now docker
step "kind $KIND_VERSION, kubectl $KUBECTL_VERSION, helm $HELM_VERSION, containerlab $CLAB_VERSION"
curl -fsSLo /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" && chmod +x /usr/local/bin/kind
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" && chmod +x /usr/local/bin/kubectl
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C /tmp && install /tmp/linux-amd64/helm /usr/local/bin/helm
bash -c "$(curl -sL https://get.containerlab.dev)" -- -v "$CLAB_VERSION" >/dev/null
kind version; containerlab version | grep -i version; helm version --short; kubectl version --client --short 2>/dev/null || kubectl version --client

step "the lab, once, through the mirrors"
umask 077; mkdir -p "$SECRETS_DIR"
printf '%s' "$FAR_PULL_B64" > "$SECRETS_DIR/cne_pull_64.json"; printf '%s' "$BNK_LICENSE_JWT" > "$SECRETS_DIR/license.jwt"; umask 022
if [ -d "$LAB_ROOT/.git" ]; then git -C "$LAB_ROOT" pull -q "https://x-access-token:${GH_READ_TOKEN}@github.com/iracic82/bnk-ai-factory-clab.git" main
else git clone -q --depth 1 "https://x-access-token:${GH_READ_TOKEN}@github.com/iracic82/bnk-ai-factory-clab.git" "$LAB_ROOT"; fi
git -C "$LAB_ROOT" remote set-url origin https://github.com/iracic82/bnk-ai-factory-clab.git
echo "lab at $(git -C "$LAB_ROOT" rev-parse --short HEAD)"
export SECRETS_DIR LICENSE_FILE=license.jwt KUBECONFIG="$LAB_ROOT/clab/kubeconfig"
cd "$LAB_ROOT"
bash install/00-host-prep.sh
bash install/05-registry-mirrors.sh
bash install/10-fabric.sh
bash install/20-cluster.sh
bash install/30-bnk.sh
bash install/35-bnk-network.sh
# the layers above BNK may still be settling on a first run; a failure there is reported, not fatal, so the harvest
# and finalise still happen and the log says exactly which step to look at
for s in 40-ai 45-observability 50-agents 60-guardrails; do
  [ -x "install/$s.sh" ] || continue
  bash "install/$s.sh" || echo "WARNING: install/$s.sh failed, see above; the bake continues"
done
# Harvest: every image any pod references (Pending ones included, a small build VM leaves some Pending) and every
# image the BNK release manifest names, pulled on one kind node so it passes through the mirrors into the cache.
# No list to maintain: the cluster is the list.
step "harvest images through the mirrors"
{ kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
  kubectl get cnemanifest -A -o yaml 2>/dev/null | grep -oE 'repo\.f5\.com/[A-Za-z0-9/_.-]+:[A-Za-z0-9._-]+'
} | grep -v '^$' | sort -u > /tmp/images.txt
echo "  $(wc -l < /tmp/images.txt) distinct images"
while read -r img; do docker exec bnk-control-plane crictl pull "$img" >/dev/null 2>&1 || echo "  could not pull $img"; done < /tmp/images.txt
# images docker itself runs (kind nodes, fabric, client, mirrors) live in docker's own cache
for i in kindest/node:v1.30.13 quay.io/frrouting/frr:10.6.2 nicolaka/netshoot:v0.14 registry:2.8.3; do docker pull -q "$i"; done
du -sh /var/lib/bnk-mirrors | sed 's/^/  mirror cache: /'
echo; echo "BAKE DONE. Now: bash $LAB_ROOT/instruqt/bnk-ai-factory-clab/build/finalise-image.sh (from a copy), stop the VM, save it."
