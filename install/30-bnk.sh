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
TARGET_MANIFEST="${TARGET_MANIFEST:-2.4.1}"

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
export BNK_NETWORK_ATTACHMENTS="external-net"   # TMM interface 1.1 = macvlan on the worker's eth1 (leaf1 eth3)
export BNK_TMM_MAPRES=true                      # maps the extra leg onto TMM's data plane
export BNK_DYNAMIC_ROUTING=true                 # BGP to the fabric
export BNK_EPP_NAMESPACES="aigw-models"
export BNK_WAIT_TIMEOUT="${BNK_WAIT_TIMEOUT:-1800}"
export BNK_REQUIRE_LICENSE=true

step "phases 00-40 (preflight, nodes, Multus, cert-manager, registry, FLO, certificates)"
for p in 00 05 10 20 30 40; do "$DEPLOY/install.sh" --env lab --profile host --phase "$p"; done

step "external-net NetworkAttachmentDefinition"
kubectl apply -f - <<'EOF'
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata: {name: external-net, namespace: f5-bnk}
spec:
  config: '{"cniVersion":"0.3.1","type":"macvlan","master":"eth1","mode":"bridge","ipam":{}}'
EOF

step "phases 50-70 (CNEInstance, licence, verify)"
for p in 50 60 70; do "$DEPLOY/install.sh" --env lab --profile host --phase "$p"; done

cur=$(kubectl get cneinstance -n f5-bnk f5-bnk-instance -o jsonpath='{.spec.manifestVersion}')
if [ "$cur" != "$TARGET_MANIFEST" ]; then
  step "upgrade $cur -> $TARGET_MANIFEST (installer's upgrade.sh)"
  "$DEPLOY/upgrade.sh" --env lab --profile host --to "$TARGET_MANIFEST"
else ok "already on $TARGET_MANIFEST"; fi

step "AI features and the EVE network model (patched on; the installer's template has no knob for them)"
# aiGateway + intelligentLB are what the lab is about. demoMode as on EVE. The legacy network model (Vrf, Vxlan,
# RoutingConfig) is the only one that carries EVPN in 2.4.1, and the controller registers its Vrf handler only with
# USE_GATEWAY_SETTINGS=false. OcNOS (ZEBOS_STATE=ocnos) is the routing stack whose BGP comes from GlobalRoutingConfig.
kubectl patch cneinstance -n f5-bnk f5-bnk-instance --type merge -p '{"spec":{
  "aiGateway":{"enabled":true,"aiMetrics":true},
  "intelligentLB":{"enabled":true},
  "advanced":{
    "demoMode":{"enabled":true},
    "envDiscovery":{"stopOnFail":true,"runAfterSuccess":true},
    "cneController":{"env":[{"name":"USE_GATEWAY_SETTINGS","value":"false"},{"name":"VRF_MODE","value":"true"},
                            {"name":"MAX_ACTIVE_TMM_REPLICAS","value":"32"},{"name":"TMM_DEFAUlT_MTU","value":"1500"}]},
    "tmm":{"env":[{"name":"TMM_CALICO_ROUTER","value":"default"},{"name":"TMM_DEFAULT_MTU","value":"1500"},
                  {"name":"TMM_MAPRES_ADDL_VETHS_ON_DP","value":"TRUE"},{"name":"ZEBOS_STATE","value":"ocnos"}]},
    "pseudoCNI":{"env":[{"name":"EXCLUDE_CIDR","value":"192.168.0.0/16,10.96.0.0/12,172.18.0.0/16"}]}
  }}}'
kubectl -n f5-bnk get cneinstance f5-bnk-instance -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
kubectl get pods -A | grep -E 'f5-|tmm' | grep -v Running | grep -v Completed || ok "every F5 pod Running"
