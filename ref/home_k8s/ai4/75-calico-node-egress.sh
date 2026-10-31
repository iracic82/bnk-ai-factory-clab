#!/bin/bash
# Host side of BNK 2.4 EgressGateway in this lab (run on bnk-cp1 as root, after 73-migrate.sh).
# CSRC builds its node->TMM VXLAN as 'local <node IP> dev ens3' to the TMM self IPs on Infra network "internal"
# (TMM's ens5 leg on the node subnet, 10.10.12.41-43), so the underlay is L2-adjacent and needs no node routes.
# Calico must not masquerade pod traffic entering the bnkvxlan* tunnels, otherwise TMM sees the node's tunnel
# IP instead of the pod IP and cannot match the tenant's EgressGateway. Masquerade only out of ens3.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl patch felixconfigurations.crd.projectcalico.org default --type merge -p '{"spec":{"iptablesNATOutgoingInterfaceFilter":"ens3"}}'
