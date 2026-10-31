#!/usr/bin/env bash
# Prometheus and Grafana (kube-prometheus-stack), for the GPU and picker metrics in chapters 3 and 4 and the
# reconstruction in chapter 12. Alertmanager is off; Grafana's admin password is generated once and kept in
# $SECRETS_DIR/grafana-admin. Both UIs are published on the host by socat units (install/lib/expose.sh).
source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/expose.sh"
need helm
KPS=92.16.1
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null 2>&1 || true

step "kube-prometheus-stack $KPS"
# not `tr </dev/urandom | head -c 20`: under pipefail head's SIGPIPE to tr fails the pipeline and set -e ends the
# script before helm runs, with no message (bake of 2026-10-31)
mkdir -p "$SECRETS_DIR"; [ -s "$SECRETS_DIR/grafana-admin" ] || { umask 077; python3 -c 'import secrets; print(secrets.token_urlsafe(15))' > "$SECRETS_DIR/grafana-admin"; }
kubectl create ns monitoring --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password="$(cat "$SECRETS_DIR/grafana-admin")" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack --version "$KPS" -n monitoring --wait --timeout "$(tmo 15m 6m)" -f - >/dev/null <<'EOF'
alertmanager: {enabled: false}
grafana:
  admin: {existingSecret: grafana-admin, userKey: admin-user, passwordKey: admin-password}
  grafana.ini:
    server: {root_url: "%(protocol)s://%(domain)s:%(http_port)s/", serve_from_sub_path: false}
    security: {allow_embedding: true}
  sidecar: {dashboards: {enabled: true, searchNamespace: ALL}}
prometheus:
  prometheusSpec:
    retention: 2d
    resources: {requests: {cpu: 200m, memory: 1Gi}}
    # scrape every ServiceMonitor/PodMonitor in the cluster, not only the chart's own
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    additionalScrapeConfigs:
    # the Dynamo mocker workers (vllm:* metrics) and the F5 picker, by pod annotation-free discovery on known ports
    - job_name: dynamo-mocker
      kubernetes_sd_configs: [{role: pod, namespaces: {names: [aigw-models]}}]
      relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_nvidia_com_dynamo_component_type], regex: decode, action: keep}
      - {source_labels: [__meta_kubernetes_pod_ip], target_label: __address__, replacement: "$1:9090"}
      - {source_labels: [__meta_kubernetes_pod_name], target_label: pod}
    - job_name: f5-epp
      kubernetes_sd_configs: [{role: pod, namespaces: {names: [aigw-models]}}]
      relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_app], regex: .*epp.*, action: keep}
      - {source_labels: [__meta_kubernetes_pod_ip], target_label: __address__, replacement: "$1:9090"}
    - job_name: fake-gpu-dcgm
      kubernetes_sd_configs: [{role: pod, namespaces: {names: [gpu-operator]}}]
      relabel_configs:
      - {source_labels: [__meta_kubernetes_pod_label_app], regex: nvidia-dcgm-exporter, action: keep}
      - {source_labels: [__meta_kubernetes_pod_ip], target_label: __address__, replacement: "$1:9400"}
      - {source_labels: [__meta_kubernetes_pod_node_name], target_label: node}
kubeEtcd: {enabled: false}
kubeControllerManager: {enabled: false}
kubeScheduler: {enabled: false}
kubeProxy: {enabled: false}
EOF
expose_service grafana monitoring kps-grafana 30300 80
expose_service prometheus monitoring kps-kube-prometheus-stack-prometheus 30909 9090
ok "Grafana on :30300 (admin, password in $SECRETS_DIR/grafana-admin), Prometheus on :30909"
