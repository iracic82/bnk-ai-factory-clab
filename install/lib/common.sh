# shellcheck shell=bash
# Shared by every install step. Source it; do not run it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/clab/kubeconfig}"
export CLAB_TOPO="$REPO_ROOT/clab/bnk-factory.clab.yml"
# Kubernetes 1.35 (BNK 2.4.x supports it; Agent Substrate needs its PodCertificateRequest API) with the Calico the EVE
# lab proved on 1.35.9. bnk-deploy is qualified on 1.30 and only warns about the difference. kind v0.32.0 image, by digest.
export KIND_NODE_IMAGE="kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"
export CALICO_VERSION="v3.32.2"
export FRR_IMAGE="quay.io/frrouting/frr:10.6.2"
export NR_HUGEPAGES=2048            # 4 GiB of 2 Mi pages: TMM asks for 2 Gi, kubelet keeps the rest in reserve
export GAIE_VERSION="v1.4.0"        # Gateway API Inference Extension; its CRDs must exist before BNK's controller starts
SECRETS_DIR="${SECRETS_DIR:-$HOME/bnk-secrets}"

# LAB_FAST=1 (set by the bake with BAKE_FAST=1) caps every long wait: the image needs the pulls, not the Ready
# states, and the harvest step caches whatever any pod references. A normal run keeps the full waits.
# usage: tmo <normal> <fast>   -> prints the one in force
tmo() { if [ "${LAB_FAST:-0}" = 1 ]; then echo "$2"; else echo "$1"; fi; }

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '   \033[33m!!\033[0m  %s\n' "$*"; }
fail() { printf '   \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed"; }
