#!/bin/bash
# Proof of per-tenant SNAT: each tenant's client curls R5's HTTP server (198.51.100.1, Loopback30, reached via VLAN 30).
# R5 answers 401 (login required); "show ip http server history" on R5 then lists the source IP per request:
# tenant-a 172.16.201.x, tenant-b 172.16.202.x, tenant-c 172.16.203.x.
export KUBECONFIG=/etc/kubernetes/admin.conf
for t in a b c; do
  printf 'tenant-%s pod %s -> ' $t "$(kubectl -n tenant-$t get pod -l app=client -o jsonpath='{.items[0].status.podIP}')"
  kubectl -n tenant-$t exec deploy/client -- curl -s -m 8 -o /dev/null -w '%{http_code}\n' http://198.51.100.1/
done
