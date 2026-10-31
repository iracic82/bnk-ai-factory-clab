#!/usr/bin/env bash
# Enable the beta APIs Agent Substrate needs (ClusterTrustBundle + PodCertificateRequest).
# Run as root. ROLE=cp on bnk-cp1 (apiserver, controller-manager, kubelet), ROLE=worker on workers (kubelet only).
set -euo pipefail
GATES="ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true"
B=/root/fg-backup-$(date +%s); mkdir -p "$B"
cp /var/lib/kubelet/config.yaml "$B/"
if ! grep -q '^featureGates:' /var/lib/kubelet/config.yaml; then
  printf 'featureGates:\n  ClusterTrustBundle: true\n  ClusterTrustBundleProjection: true\n  PodCertificateRequest: true\n' >> /var/lib/kubelet/config.yaml
fi
if [ "${ROLE:-worker}" = cp ]; then
  M=/etc/kubernetes/manifests
  cp $M/kube-apiserver.yaml $M/kube-controller-manager.yaml "$B/"
  for f in kube-apiserver kube-controller-manager; do
    grep -q -- "--feature-gates=" $M/$f.yaml || sed -i "0,/^    - $f\$/s//    - $f\n    - --feature-gates=$GATES/" $M/$f.yaml
  done
  grep -q -- "--runtime-config=" $M/kube-apiserver.yaml || \
    sed -i "0,/^    - kube-apiserver\$/s//    - kube-apiserver\n    - --runtime-config=certificates.k8s.io\/v1beta1=true/" $M/kube-apiserver.yaml
  # wait for the apiserver; roll back if it does not return
  sleep 20
  for i in $(seq 1 30); do
    kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw /readyz >/dev/null 2>&1 && break
    sleep 5
    if [ $i = 30 ]; then echo "apiserver did not return, rolling back"; cp $B/kube-*.yaml $M/; exit 1; fi
  done
fi
systemctl restart kubelet
echo "gates enabled, backup in $B"
