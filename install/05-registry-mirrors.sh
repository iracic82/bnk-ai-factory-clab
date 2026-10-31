#!/usr/bin/env bash
# Pull-through registry mirrors on the host, one per upstream, so the kind nodes never pull from the internet
# twice. At bake time the first install fills them; the baked image carries /var/lib/bnk-mirrors; at track start
# every image comes from local disk. No list of images to maintain: whatever the install pulls is what is cached.
#
# A registry:2 instance can proxy exactly one upstream, hence one container per upstream. repo.f5.com needs the
# FAR credential (username _json_key_base64, password = the file's contents, the same pair bnk-deploy uses).
# The mirrors listen on the kind bridge gateway address and loopback only, so nothing is offered on the LAN.
source "$(dirname "$0")/lib/common.sh"
need docker

MIRROR_DIR="${MIRROR_DIR:-/var/lib/bnk-mirrors}"
# upstream host -> local port. 10-fabric.sh writes matching hosts.toml files into every kind node.
declare -A MIRRORS=( [docker.io]=5001 [quay.io]=5002 [ghcr.io]=5003 [registry.k8s.io]=5004 [nvcr.io]=5005 [repo.f5.com]=5006 [gcr.io]=5007 )
remote() { case "$1" in docker.io) echo https://registry-1.docker.io ;; *) echo "https://$1" ;; esac; }

sudo mkdir -p "$MIRROR_DIR"
docker network inspect kind >/dev/null 2>&1 || docker network create kind >/dev/null
BIND_IP=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}')
[ -n "$BIND_IP" ] || fail "cannot find the kind network gateway address"
echo "$BIND_IP" | sudo tee "$MIRROR_DIR/.bind" >/dev/null

step "mirrors on $BIND_IP"
for up in "${!MIRRORS[@]}"; do
  port=${MIRRORS[$up]}; name="mirror-${up//./-}"
  env=(-e REGISTRY_PROXY_REMOTEURL="$(remote "$up")" -e REGISTRY_STORAGE_DELETE_ENABLED=true)
  if [ "$up" = repo.f5.com ]; then
    f="${FAR_PULL_JSON:-$SECRETS_DIR/cne_pull_64.json}"; [ -r "$f" ] || fail "FAR_PULL_JSON $f not readable (needed for the repo.f5.com mirror)"
    # the credential goes in through the environment of this one container, never onto disk in the image
    env+=(-e REGISTRY_PROXY_USERNAME=_json_key_base64 -e REGISTRY_PROXY_PASSWORD="$(tr -d '\n\r ' < "$f")")
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --restart unless-stopped \
    -p "$BIND_IP:$port:5000" -p "127.0.0.1:$port:5000" \
    -v "$MIRROR_DIR/$up:/var/lib/registry" "${env[@]}" registry:2.8.3 >/dev/null
  ok "$up -> $BIND_IP:$port"
done
sleep 2
for up in "${!MIRRORS[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${MIRRORS[$up]}/v2/" || true)
  [ "$code" = 200 ] || warn "$up mirror answered $code"
done
du -sh "$MIRROR_DIR" 2>/dev/null | sed 's/^/   cache: /'
