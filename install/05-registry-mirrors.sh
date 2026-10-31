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
  mounts=(-v "$MIRROR_DIR/$up:/var/lib/registry")
  cfg=""
  if [ "$up" = repo.f5.com ]; then
    f="${FAR_PULL_JSON:-$SECRETS_DIR/cne_pull_64.json}"; [ -r "$f" ] || fail "FAR_PULL_JSON $f not readable (needed for the repo.f5.com mirror)"
    # The credential reaches the container as a mounted config file, not as an environment variable that
    # `docker inspect` would show. The file is removed from disk once the container has read it (the mount
    # keeps working), and finalise-image.sh removes the container itself, so the baked image holds no copy.
    cfg=$(mktemp -p "${SECRETS_DIR}" mirror-XXXXXX.yml); chmod 600 "$cfg"
    # block-style YAML: ":5000" inside a flow mapping does not parse, and the registry then prints its usage and exits
    python3 - "$f" "$cfg" "$(remote "$up")" <<'EOF'
import sys, json
far, cfg, url = sys.argv[1:]
pw = open(far).read().strip()
open(cfg, 'w').write("version: 0.1\n"
                     "log:\n  level: warn\n"
                     "storage:\n  filesystem:\n    rootdirectory: /var/lib/registry\n  delete:\n    enabled: true\n"
                     "http:\n  addr: :5000\n"
                     f"proxy:\n  remoteurl: {url}\n  username: _json_key_base64\n  password: {json.dumps(pw)}\n")
EOF
    mounts+=(-v "$cfg:/etc/docker/registry/config.yml:ro"); env=()
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --restart unless-stopped \
    -p "$BIND_IP:$port:5000" -p "127.0.0.1:$port:5000" "${mounts[@]}" "${env[@]}" registry:2.8.3 >/dev/null
  # the registry reads its config once at start; only after it answers may the file with the credential go
  code=000
  for _ in $(seq 1 30); do code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v2/" || true); [ "$code" = 200 ] && break; sleep 1; done
  if [ "$code" != 200 ]; then
    warn "$up mirror answered $code after 30 s; its log:"; docker logs --tail 5 "$name" 2>&1 | sed 's/^/      /'
  fi
  [ -n "$cfg" ] && { shred -u "$cfg" 2>/dev/null || rm -f "$cfg"; }
  ok "$up -> $BIND_IP:$port ($code)"
done
du -sh "$MIRROR_DIR" 2>/dev/null | sed 's/^/   cache: /'
