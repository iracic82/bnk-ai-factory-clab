#!/usr/bin/env bash
# BNK itself, through the shared installer, unmodified. iracic82/bnk-deploy is public and is cloned into .cache/.
#
# The installer pins 2.4.0 (its versions.env is sourced, so it cannot be overridden from here) and I do not edit
# it. So: install 2.4.0, then raise it to 2.4.1 with the installer's own upgrade.sh, which is the documented FLO
# upgrade path (helm upgrade the operator, raise manifestVersion, re-apply the licence) with a health gate.
#
# Secrets, from the process environment only, as the installer wants them:
#   FAR_PULL_JSON     path to cne_pull_64.json            (default: $SECRETS_DIR/cne_pull_64.json)
#   BNK_LICENSE_JWT   the licence token                    (default: contents of $SECRETS_DIR/$LICENSE_FILE,
#                                                            LICENSE_FILE defaults to spk-eval-igor.jwt)
#
# Phases 00-40 run first, then the NetworkAttachmentDefinition for TMM's external leg is created (Multus arrives in
# phase 10, and FLO needs the NAD to exist before the CNEInstance in phase 50 names it), then 50-70.
source "$(dirname "$0")/lib/common.sh"
kubectl get node bnk-worker -L app --no-headers | grep -q f5-tmm || fail "bnk-worker is not labelled app=f5-tmm; run 20-cluster.sh"

DEPLOY="$REPO_ROOT/.cache/bnk-deploy"
BNK_DEPLOY_REF="${BNK_DEPLOY_REF:-main}"
# 2.4.2 is a critical release (PHP CVE fixes on top of 2.4.1, no feature change per its release notes) and is in the registry
TARGET_MANIFEST="${TARGET_MANIFEST:-2.4.2}"

step "installer"
if [ -d "$DEPLOY/.git" ]; then git -C "$DEPLOY" fetch -q origin "$BNK_DEPLOY_REF" && git -C "$DEPLOY" checkout -q FETCH_HEAD
else git clone -q --depth 1 --branch "$BNK_DEPLOY_REF" https://github.com/iracic82/bnk-deploy.git "$DEPLOY"; fi
ok "bnk-deploy $(git -C "$DEPLOY" rev-parse --short HEAD)"

export FAR_PULL_JSON="${FAR_PULL_JSON:-$SECRETS_DIR/cne_pull_64.json}"
[ -r "$FAR_PULL_JSON" ] || fail "FAR_PULL_JSON $FAR_PULL_JSON is not readable"
LICENSE_FILE="${LICENSE_FILE:-spk-eval-igor.jwt}"
if [ -z "${BNK_LICENSE_JWT:-}" ]; then
  [ -r "$SECRETS_DIR/$LICENSE_FILE" ] || fail "no BNK_LICENSE_JWT and no $SECRETS_DIR/$LICENSE_FILE"
  BNK_LICENSE_JWT="$(tr -d '\n\r ' < "$SECRETS_DIR/$LICENSE_FILE")"; export BNK_LICENSE_JWT
fi

# Knobs the installer's host profile and lab environment accept from the caller (profiles/host.env keeps ${VAR:-})
export BNK_TMM_NODES=bnk-worker BNK_TMM_MANAGE_LABELS=true
export BNK_STORAGECLASS=standard
export BNK_NETWORK_ATTACHMENTS="external-net,internal-net"   # TMM 1.1 = macvlan on eth1 (leaf1 eth3), 1.2 = macvlan on eth0 (node net)
export BNK_TMM_MAPRES=true                      # maps the extra leg onto TMM's data plane
# Dynamic routing stays OFF for the install: with it on, TMM's init-f5-tmm-routing container waits for a routing
# configuration (GlobalRoutingConfig) that 35-bnk-network.sh can only apply once BNK is up, and the installer waits
# for TMM: a deadlock (bake of 2026-10-31). The patch below switches it on; step 35 applies the configs first thing.
export BNK_DYNAMIC_ROUTING=false
export BNK_EPP_NAMESPACES="aigw-models"
export BNK_WAIT_TIMEOUT="${BNK_WAIT_TIMEOUT:-$(tmo 1800 600)}"
export BNK_REQUIRE_LICENSE=true

step "phases 00-40 (preflight, nodes, Multus, cert-manager, registry, FLO, certificates)"
for p in 00 05 10 20 30 40; do "$DEPLOY/install.sh" --env lab --profile host --phase "$p"; done

# the CNEInstance names eppNamespaces=aigw-models; the controller watches that namespace from its first start, so it
# has to exist before phase 50 (40-ai.sh fills it later)
kubectl create ns aigw-models --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label ns aigw-models aigw.lab/engine=dynamo --overwrite >/dev/null
# ... and with EPP namespaces set, the controller also starts an informer on InferencePool at boot and exits when the
# CRD is absent ("failed to wait for f5epp caches to sync kind source: *v1.InferencePool", bake of 2026-10-31). It
# then never configures TMM, F5TmmAvailable stays false and phase 50 times out. So the inference CRDs go in here.
step "Gateway API Inference Extension CRDs $GAIE_VERSION (the controller watches InferencePool from its first start)"
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$GAIE_VERSION/manifests.yaml" >/dev/null
kubectl wait --for=condition=Established crd/inferencepools.inference.networking.k8s.io --timeout=60s >/dev/null
step "NetworkAttachmentDefinitions for TMM's legs (order = TMM interface number)"
kubectl apply -f - <<'EOF'
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: {name: external-net, namespace: f5-bnk}
spec:
  config: '{"cniVersion":"0.3.1","type":"macvlan","master":"eth1","mode":"bridge","ipam":{}}'
---
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: {name: internal-net, namespace: f5-bnk}
spec:
  config: '{"cniVersion":"0.3.1","type":"macvlan","master":"eth0","mode":"bridge","ipam":{}}'
EOF

step "phases 50-70 (CNEInstance, licence, verify)"
for p in 50 60 70; do "$DEPLOY/install.sh" --env lab --profile host --phase "$p"; done

cur=$(kubectl get cneinstance -n f5-bnk f5-bnk-instance -o jsonpath='{.spec.manifestVersion}')
if [ "$cur" != "$TARGET_MANIFEST" ]; then
  step "upgrade $cur -> $TARGET_MANIFEST (installer's upgrade.sh)"
  "$DEPLOY/upgrade.sh" --env lab --profile host --to "$TARGET_MANIFEST"
else ok "already on $TARGET_MANIFEST"; fi

step "AI features and the EVE network model (patched on; the installer's template has no knob for them)"
# pseudoCNI must leave pod, service and node-network traffic alone; the node network is whatever docker gave kind
KIND_SUBNET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Subnet}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+/' | head -1)
# aiGateway + intelligentLB are what the lab is about. demoMode as on EVE. The legacy network model (Vrf, Vxlan,
# RoutingConfig) is the only one that carries EVPN in 2.4.1, and the controller registers its Vrf handler only with
# USE_GATEWAY_SETTINGS=false. OcNOS (ZEBOS_STATE=ocnos) is the routing stack whose BGP comes from GlobalRoutingConfig.
kubectl patch cneinstance -n f5-bnk f5-bnk-instance --type merge -p '{"spec":{"advanced":{"pseudoCNI":{"env":[{"name":"EXCLUDE_CIDR","value":"192.168.0.0/16,10.96.0.0/12,'"$KIND_SUBNET"'"}]}}}}' >/dev/null
kubectl patch cneinstance -n f5-bnk f5-bnk-instance --type merge -p '{"spec":{
  "aiGateway":{"enabled":true,"aiMetrics":true},
  "intelligentLB":{"enabled":true},
  "dynamicRouting":{"enabled":true},
  "advanced":{
    "demoMode":{"enabled":true},
    "envDiscovery":{"stopOnFail":true,"runAfterSuccess":true},
    "cneController":{"env":[{"name":"USE_GATEWAY_SETTINGS","value":"false"},{"name":"VRF_MODE","value":"true"},
                            {"name":"MAX_ACTIVE_TMM_REPLICAS","value":"32"},{"name":"TMM_DEFAUlT_MTU","value":"1500"}]},
    "tmm":{"env":[{"name":"TMM_CALICO_ROUTER","value":"default"},{"name":"TMM_DEFAULT_MTU","value":"1500"},
                  {"name":"TMM_MAPRES_ADDL_VETHS_ON_DP","value":"TRUE"},{"name":"ZEBOS_STATE","value":"ocnos"}]}
  }}}'
kubectl -n f5-bnk get cneinstance f5-bnk-instance -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
kubectl get pods -A | grep -E 'f5-|tmm' | grep -v Running | grep -v Completed || ok "every F5 pod Running"
