#!/usr/bin/env bash
# Re-run the image harvest on a built lab: (re)start the mirrors, then pull every image any pod references and
# every image the BNK manifest names through them. For a bake whose mirrors came up late, or to top up the cache
# after adding a component. Needs the FAR credential on disk (SECRETS_DIR/cne_pull_64.json) for the repo.f5.com mirror.
set -euo pipefail
LAB_ROOT="${LAB_ROOT:-/root/lab}"; export SECRETS_DIR="${SECRETS_DIR:-/root/.bnk}" KUBECONFIG="${KUBECONFIG:-$LAB_ROOT/clab/kubeconfig}"
cd "$LAB_ROOT"
bash install/05-registry-mirrors.sh
# make sure every node's containerd points at the mirrors (10-fabric.sh does this on a fresh deploy)
BIND_IP=$(cat /var/lib/bnk-mirrors/.bind)
declare -A MIRRORS=( [docker.io]=5001 [quay.io]=5002 [ghcr.io]=5003 [registry.k8s.io]=5004 [nvcr.io]=5005 [repo.f5.com]=5006 [gcr.io]=5007 )
for n in bnk-control-plane bnk-worker bnk-worker2; do
  for up in "${!MIRRORS[@]}"; do
    docker exec "$n" sh -c "mkdir -p /etc/containerd/certs.d/$up && printf 'server = \"https://%s\"\n\n[host.\"http://%s:%s\"]\n  capabilities = [\"pull\", \"resolve\"]\n' '$up' '$BIND_IP' '${MIRRORS[$up]}' > /etc/containerd/certs.d/$up/hosts.toml"
  done
done
{ kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
  kubectl get cnemanifest -A -o yaml 2>/dev/null | grep -oE 'repo\.f5\.com/[A-Za-z0-9/_.-]+:[A-Za-z0-9._-]+'
} | grep -v '^$' | sort -u > /tmp/images.txt
echo "$(wc -l < /tmp/images.txt) distinct images"
# a node already holding an image will not re-pull it; remove it from one node's store first so the pull goes
# through the mirror and lands in the cache (the other nodes keep their copies)
while read -r img; do
  docker exec bnk-control-plane crictl rmi "$img" >/dev/null 2>&1 || true
  docker exec bnk-control-plane crictl pull "$img" >/dev/null 2>&1 && printf '.' || printf '\n  could not pull %s\n' "$img"
done < /tmp/images.txt; echo
f5=$(find /var/lib/bnk-mirrors/repo.f5.com -path '*repositories*' -name '_manifests' 2>/dev/null | wc -l)
echo "repo.f5.com repositories cached: $f5   cache: $(du -sh /var/lib/bnk-mirrors | cut -f1)"
