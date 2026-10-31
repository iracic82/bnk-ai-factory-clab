# shellcheck shell=bash
# Shared by every install step. Source it; do not run it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/clab/kubeconfig}"
export CLAB_TOPO="$REPO_ROOT/clab/bnk-factory.clab.yml"
# Same pins as bnk-deploy/versions.env for K8S_MINOR 1.30, so the installer's preflight sees what its CI sees
export KIND_NODE_IMAGE="kindest/node:v1.30.13"
export CALICO_VERSION="v3.29.1"
export FRR_IMAGE="frrouting/frr:10.2.1"
export NR_HUGEPAGES=2048            # 4 GiB of 2 Mi pages: TMM asks for 2 Gi, kubelet keeps the rest in reserve
SECRETS_DIR="${SECRETS_DIR:-$HOME/bnk-secrets}"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '   \033[33m!!\033[0m  %s\n' "$*"; }
fail() { printf '   \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed"; }
