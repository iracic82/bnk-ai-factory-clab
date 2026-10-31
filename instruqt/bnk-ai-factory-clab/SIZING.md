# Sizing

One VM, n2-standard-32 (32 vCPU, 128 GB), custom image with a 100 GB disk.

## Why 32 vCPU

Measured on a licensed BNK install (`bnk-ai-factory-real/SIZING.md`), requests, not usage:

| What | vCPU |
|---|---|
| BNK DaemonSets, every node (3 kind nodes) | 3 x 0.85 = 2.55 |
| BNK control plane, schedulable anywhere | 15.40 |
| f5-tmm, on the one node labelled app=f5-tmm | 4.60, plus 8 Gi memory and 2 Gi of 2 Mi hugepages |
| **BNK total** | **22.55** |
| Dynamo platform + NATS + 2 mocker workers | ~1.5 |
| fake GPU operator + KAI | ~0.5 |
| kagent, OpenShell gateway, Substrate, 3 tenant agents, CPU qwen | ~3 |
| Prometheus, Grafana, Polaris console, ClickHouse | ~1.5 |
| FRR fabric (6 containers), client, registry mirrors | ~0.5 |
| **Total requested** | **~29.5** |

kind nodes all advertise the host's CPUs, so Kubernetes sees 3 x 32 = 96 allocatable and never refuses a pod on
CPU; what matters is that real usage stays under 32. Idle BNK plus the lab layer measured about 6 cores on EVE;
the simulators under a learner's load another 4 to 6. There is room.

## Why not three VMs

Instruqt VMs share one flat sandbox network. There is no way to attach a second VM's NIC to "leaf1 eth3", so
three VMs would need gretap or VXLAN tunnels into the fabric VM, which is less like a real rack than kind nodes
with a veth straight into a leaf. The resource bill is identical either way (22.55 vCPU is BNK's, wherever it
runs), and one VM removes the sequential-setup trap, the ssh-and-join step and two images.

## Disk

| What | GB |
|---|---|
| OS, docker, tooling | ~6 |
| registry mirrors: repo.f5.com (81 components) | ~5 |
| mirrors: calico, multus, cert-manager, kind node, FRR, dynamo, fake GPU, KAI, kagent, OpenShell, ollama + qwen | ~8 |
| kind node containers at run time (3 x ~5 GB image stores filled from the mirrors) | ~15 |
| local-path volumes (ClickHouse, Prometheus, NATS, postgres for kagent) | ~10 |
| headroom for logs, learner work | rest |

Stock Instruqt images have a 10 GB disk and no way to change it; that is why the image is custom.

## Hugepages

`vm.nr_hugepages = 2048` (4 GiB) on the VM kernel. TMM requests 2 Gi and the operator keeps that request
whatever you override; kind nodes share the kernel and advertise the pages after a kubelet restart
(`install/20-cluster.sh`).
