#!/usr/bin/env bash
# The KAI demo in three steps: tenant-b borrows idle GPUs, tenant-a takes its quota back, tenant-c shares one GPU.
#   KUBECONFIG=~/.kube/bnk-eve.config install/gpu/demo/run.sh          # run it
#   KUBECONFIG=~/.kube/bnk-eve.config install/gpu/demo/run.sh clean    # remove the demo workloads
set -uo pipefail
cd "$(dirname "$0")"
clean() { kubectl delete -f tenant-a-claim.yaml -f tenant-b-borrow.yaml -f tenant-c-fraction.yaml --ignore-not-found --wait; }
[ "${1:-}" = clean ] && { clean; exit; }
show() {
  echo "== $1"
  kubectl get pods -A -l 'app in (gpu-demo,gpu-demo-half)' --no-headers -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName' | sort
  kubectl get queues.scheduling.run.ai tenant-a tenant-b tenant-c -o json | python3 -c '
import json, sys
for q in json.load(sys.stdin)["items"]:
    g = q.get("status", {}).get("allocated", {}).get("nvidia.com/gpu", "0")
    g = round(int(g[:-1]) / 1e9, 1) if g.endswith("n") else g  # fractions come back in nano units
    print("  queue %s: %s GPUs (quota %s)" % (q["metadata"]["name"], g, q["spec"]["resources"]["gpu"]["quota"]))'
}
wait_running() { # $1 ns, $2 label, $3 count
  for _ in $(seq 1 40); do
    [ "$(kubectl -n $1 get pods -l app=$2 --no-headers 2>/dev/null | grep -c Running)" -ge $3 ] && return; sleep 5
  done
}
clean >/dev/null 2>&1
kubectl apply -f tenant-b-borrow.yaml >/dev/null; wait_running tenant-b gpu-demo 6
show "1. tenant-b (quota 2) borrows 6 of the 8 idle GPUs"
kubectl apply -f tenant-a-claim.yaml >/dev/null; wait_running tenant-a gpu-demo 4
show "2. tenant-a asks for its quota of 4: KAI reclaims tenant-b's borrowed GPUs"
kubectl apply -f tenant-c-fraction.yaml >/dev/null; wait_running tenant-c gpu-demo-half 2
show "3. tenant-c runs two pods on half a GPU each"
for p in $(kubectl -n tenant-c get pods -l app=gpu-demo-half -o name); do echo "  $p: $(kubectl -n tenant-c logs $p)"; done
