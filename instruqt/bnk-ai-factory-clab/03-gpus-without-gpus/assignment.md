---
slug: gpus-without-gpus
id: 8dv8o9oetqmn
type: challenge
title: 3. GPUs without GPUs
teaser: NVIDIA's own simulators give the cluster eight H100s it does not have and
  two model workers that behave like vLLM. KAI shares the GPUs between the tenants
  by quota. Submit work for each tenant and watch who gets what.
notes:
- type: text
  contents: |-
    **Northlight Compute, week two.** The customers bought GPU hours. The lab has no GPUs. NVIDIA's simulators
    make the cluster believe it has eight H100s and make the scheduler fight over them exactly as it would in
    the real hall, quota by quota, tenant by tenant.

    Two NVIDIA pieces make the GPU side real enough to schedule and measure:

    - the **fake GPU operator** (from Run:ai) advertises `nvidia.com/gpu` on the workers with the labels a real GPU
      operator would set (`nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3`), and runs a DCGM exporter with
      plausible metrics
    - the **Dynamo mocker** runs NVIDIA Dynamo's frontend and two decode workers that simulate vLLM: they publish
      `vllm:*` metrics and KV-cache events to NATS, which is what F5's Endpoint Picker reads in the next chapter

    Scheduling is the tenant boundary here: the **KAI scheduler** (Run:ai's scheduler, open-sourced by NVIDIA) owns
    the eight GPUs through a parent queue and gives each tenant a quota it is guaranteed, with borrowing allowed
    while others are idle.
tabs:
- id: 5auxikf1bnng
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: gzmkrcdfttym
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: 39op6gnznijm
  title: Grafana
  type: service
  hostname: factory
  port: 30300
- id: dumetxe5n2de
  title: Prometheus
  type: service
  hostname: factory
  port: 30909
- id: zgqdiyx3kqa1
  title: Lab Topology
  type: service
  hostname: factory
  path: /topology
  port: 5050
difficulty: basic
timelimit: 1200
enhanced_loading: false
---

![03-gpus-without-gpus](../assets/03-gpus-without-gpus.svg)

## The GPUs the cluster thinks it has

```bash,run
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,PRODUCT:.metadata.labels.nvidia\.com/gpu\.product'
kubectl get queues.scheduling.run.ai -o custom-columns='QUEUE:.metadata.name,PARENT:.spec.parentQueue,QUOTA:.spec.resources.gpu.quota,LIMIT:.spec.resources.gpu.limit,WEIGHT:.spec.resources.gpu.overQuotaWeight'
```

Aurora is guaranteed 4, Borealis and Cobalt 2 each; any of them may borrow idle GPUs (`limit: -1`), and Aurora's
borrowing weight is double.

## Submit work per tenant

A job that asks for GPUs, scheduled by KAI, in a tenant's queue:

```bash,run
gpu_job() {   # tenant gpus
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata: {name: train-$RANDOM, namespace: tenant-$1, labels: {kai.scheduler/queue: tenant-$1}}
spec:
  template:
    metadata: {labels: {kai.scheduler/queue: tenant-$1}}
    spec:
      schedulerName: kai-scheduler
      restartPolicy: Never
      containers:
      - name: train
        image: python:3.12-slim
        command: [sh, -c, "echo training on \$NVIDIA_VISIBLE_DEVICES; sleep 600"]
        resources: {limits: {nvidia.com/gpu: "$2"}}
EOF
}
gpu_job a 4; gpu_job b 2; gpu_job c 2
sleep 15; kubectl get pods -A -l kai.scheduler/queue -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName'
```

All eight GPUs are in use. Now Cobalt asks for four more; it is over its quota and nothing is idle, so it waits:

```bash,run
gpu_job c 4
sleep 15; kubectl -n tenant-c get pods -o custom-columns='POD:.metadata.name,STATUS:.status.phase'
kubectl -n tenant-c get events --field-selector reason=Unschedulable -o custom-columns='MSG:.message' | tail -3
```

Free Aurora's job and watch Cobalt's pending job take the GPUs. Aurora can reclaim them at any time: its quota is
guaranteed, Cobalt's extra ones are borrowed.

```bash,run
kubectl -n tenant-a delete jobs --all
sleep 20; kubectl get pods -A -l kai.scheduler/queue -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase'
```

## What a pod sees

Inside a scheduled pod the GPU looks real:

```bash,run
P=$(kubectl -n tenant-c get pods -l kai.scheduler/queue --field-selector status.phase=Running -o name | head -1)
kubectl -n tenant-c exec $P -- sh -c 'echo "devices: $NVIDIA_VISIBLE_DEVICES"; nvidia-smi 2>/dev/null | head -12 || echo "(no nvidia-smi binary in this image; the device is in the environment)"'
```

## The model workers

The mocker's workers publish vLLM's metrics. Prometheus scrapes them; Grafana shows them (admin, password below):

```bash,run
kubectl -n aigw-models get pods -o wide
cat /root/.bnk/grafana-admin; echo
```

Open the **Grafana** tab, Explore, and query `vllm:num_requests_running` and `DCGM_FI_DEV_GPU_UTIL`. Both exist
without a single GPU in the VM.

Clean up the jobs, then click **Check**:

```bash,run
for t in a b c; do kubectl -n tenant-$t delete jobs --all --ignore-not-found; done
```
