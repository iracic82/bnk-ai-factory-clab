#!/usr/bin/env bash
# Generates the fabric configs and deploys the containerlab topology, which also creates the kind cluster and
# attaches each kind worker's eth1 to its leaf. Idempotent: a second run reconfigures instead of failing.
#
# Two things containerlab 0.75 does with k8s-kind that shape this script:
#   - it waits (15 min) for the kind control plane to be Ready before attaching links, and a cluster created with
#     disableDefaultCNI is never Ready until a CNI arrives. So the deploy runs in the background and Calico is
#     installed as soon as the API answers; the deploy then completes on its own.
#   - it has no per-node kubeconfig field and kind writes the context into the user's ~/.kube/config. The context
#     is exported into clab/kubeconfig and removed from ~/.kube/config again.
source "$(dirname "$0")/lib/common.sh"

step "fabric configs"
python3 "$REPO_ROOT/fabric/gen.py"

step "containerlab deploy ($CLAB_TOPO)"
cd "$REPO_ROOT/clab"
LOG="$REPO_ROOT/clab/deploy.log"
if docker ps --format '{{.Names}}' | grep -qx bnk-control-plane; then
  containerlab deploy -t "$CLAB_TOPO" --reconfigure >"$LOG" 2>&1 &
else
  containerlab deploy -t "$CLAB_TOPO" >"$LOG" 2>&1 &
fi
DEPLOY_PID=$!

until kind get clusters 2>/dev/null | grep -qx bnk && kind export kubeconfig --name bnk --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 \
      && kubectl get nodes >/dev/null 2>&1; do
  kill -0 "$DEPLOY_PID" 2>/dev/null || { cat "$LOG"; fail "containerlab deploy exited before the kind cluster existed"; }
  sleep 5
done
kubectl config use-context kind-bnk >/dev/null
ok "kind cluster bnk is answering; kubeconfig at $KUBECONFIG"

# Point every node's containerd at the pull-through mirrors from 05-registry-mirrors.sh (hosts.toml per upstream,
# the layout kind's own local-registry guide uses). Without mirrors running this is skipped and nodes pull direct.
MIRROR_DIR="${MIRROR_DIR:-/var/lib/bnk-mirrors}"
if [ -r "$MIRROR_DIR/.bind" ]; then
  BIND_IP=$(cat "$MIRROR_DIR/.bind")
  declare -A MIRRORS=( [docker.io]=5001 [quay.io]=5002 [ghcr.io]=5003 [registry.k8s.io]=5004 [nvcr.io]=5005 [repo.f5.com]=5006 [gcr.io]=5007 )
  for n in bnk-control-plane bnk-worker bnk-worker2; do
    for up in "${!MIRRORS[@]}"; do
      docker exec "$n" sh -c "mkdir -p /etc/containerd/certs.d/$up && printf 'server = \"https://%s\"\n\n[host.\"http://%s:%s\"]\n  capabilities = [\"pull\", \"resolve\"]\n' '$up' '$BIND_IP' '${MIRRORS[$up]}' > /etc/containerd/certs.d/$up/hosts.toml"
    done
  done
  ok "containerd on every node reads images through the mirrors at $BIND_IP"
else
  warn "no registry mirrors (run 05-registry-mirrors.sh first); nodes pull from the internet"
fi

step "Calico $CALICO_VERSION (nodes stay NotReady without a CNI, and containerlab waits for Ready)"
kubectl get ns tigera-operator >/dev/null 2>&1 || \
  kubectl create -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" >/dev/null
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s >/dev/null
until kubectl get crd installations.operator.tigera.io >/dev/null 2>&1; do sleep 2; done
kubectl apply -f - <<'EOF' >/dev/null
apiVersion: operator.tigera.io/v1
kind: Installation
metadata: {name: default}
spec:
  calicoNetwork:
    ipPools:
    - {cidr: 192.168.0.0/16, encapsulation: VXLANCrossSubnet, natOutgoing: Enabled, nodeSelector: all()}
    # the kind docker network, not the fabric link: TMM owns eth1
    nodeAddressAutodetectionV4: {interface: eth0}
EOF
kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null
ok "nodes Ready"

wait "$DEPLOY_PID" || { tail -40 "$LOG"; fail "containerlab deploy failed, full log in $LOG"; }
# kind merged its context into the user's kubeconfig as a side effect; this lab keeps its own file
kubectl --kubeconfig "$HOME/.kube/config" config delete-context kind-bnk >/dev/null 2>&1 || true
kubectl --kubeconfig "$HOME/.kube/config" config delete-cluster kind-bnk >/dev/null 2>&1 || true
kubectl --kubeconfig "$HOME/.kube/config" config delete-user kind-bnk >/dev/null 2>&1 || true
ok "containerlab deploy finished"

step "cluster"
kubectl get nodes -o wide
step "worker handoff links"
for n in bnk-worker bnk-worker2; do printf '%-12s %s\n' "$n" "$(docker exec "$n" ip -br link show eth1)"; done
step "fabric sessions (leaf1)"
docker exec leaf1 vtysh -c 'show bgp summary' | sed -n '1,40p'
