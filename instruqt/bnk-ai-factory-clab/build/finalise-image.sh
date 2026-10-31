#!/usr/bin/env bash
# Second half of the bake: keep the tooling and the mirror cache, remove everything else (cluster, fabric, lab
# clone, secrets, logs), then check nothing sensitive is left. Run from a copy outside the clone.
set -uo pipefail
fail() { echo; echo "FAILED: $*" >&2; exit 1; }
step() { echo; echo "### $*"; }
LAB_ROOT="${LAB_ROOT:-/root/lab}"; SECRETS_DIR="${SECRETS_DIR:-/root/.bnk}"; MIRROR_DIR=/var/lib/bnk-mirrors

step "is the cache worth saving"
f5=$(find "$MIRROR_DIR/repo.f5.com" -path '*repositories*' -name '_manifests' 2>/dev/null | wc -l)
size=$(du -sh "$MIRROR_DIR" 2>/dev/null | cut -f1)
echo "  repo.f5.com repositories cached: $f5, mirror size: $size"
[ "$f5" -ge 20 ] || fail "only $f5 repo.f5.com repositories cached; let the bake finish before saving"

step "tearing down the lab, keeping the mirrors"
[ -f "$LAB_ROOT/clab/bnk-factory.clab.yml" ] && (cd "$LAB_ROOT/clab" && containerlab destroy -t bnk-factory.clab.yml --cleanup >/dev/null 2>&1 || true)
kind delete cluster --name bnk >/dev/null 2>&1 || true
# the mirror containers go (the repo.f5.com one carries the FAR credential in its mounted config); the cache under
# /var/lib/bnk-mirrors stays, and 05-registry-mirrors.sh recreates the containers at track start
docker ps -aq --filter name='^mirror-' | xargs -r docker rm -f >/dev/null
docker system prune -af --volumes >/dev/null 2>&1 || true
step "secrets and clone"
shred -u "$SECRETS_DIR"/* 2>/dev/null; rm -rf "$SECRETS_DIR" "$LAB_ROOT" /root/.kube /root/.config/helm/registry /root/.docker
rm -f /root/.bash_history /root/.python_history; history -c 2>/dev/null || true
step "apt and logs"
apt-get clean; rm -rf /var/lib/apt/lists/*; journalctl --rotate 2>/dev/null; journalctl --vacuum-time=1s 2>/dev/null
rm -f /var/log/bake-image.log

step "nothing sensitive left"
if grep -rIl -e '-----BEGIN' -e '"private_key"' /root /etc/docker /var/lib/docker/containers 2>/dev/null | head -3 | grep .; then
  fail "key material found, see above"; fi
echo
echo "================================================================"
echo " READY TO SAVE   mirrors: $size   disk: $(df -h / | tail -1 | awk '{print $3" of "$2}')"
echo " Stop the VM and save it as f5/bnk-clab."
echo "================================================================"
