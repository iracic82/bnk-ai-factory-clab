---
slug: the-factory
id: 0opjtgxzor87
type: challenge
title: 1. One VM, a whole factory
teaser: A spine/leaf/border EVPN fabric, an exit router, a client and a three node
  Kubernetes cluster with BNK on it, all on the machine you are logged into. Walk
  it before you change anything.
notes:
- type: text
  contents: |-
    Everything in this lab runs on this one VM. containerlab built an FRR fabric (two spines, two leaves, a
    border router), an exit router `r5`, a client, and a kind cluster with three nodes. The kind workers have a
    real second interface cabled into the leaves, and F5 BIG-IP Next for Kubernetes (TMM) sits on that interface
    with a BGP session to leaf1.

    In this first chapter you look at each piece from the outside in: the fabric's routes, the cluster's nodes,
    TMM's session, and a request from the client that crosses all of it.
tabs:
- id: vug5lxsr4kxz
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: ymd9odlmnb7g
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: ylrgyhyyfvvx
  title: Polaris
  type: service
  hostname: factory
  port: 30443
difficulty: basic
timelimit: 900
enhanced_loading: false
---

## The fabric

Every fabric node is a container. `vtysh` on leaf1 shows the underlay (eBGP unnumbered to both spines) and the
overlay (EVPN on the same sessions):

```bash,run
docker exec leaf1 vtysh -c 'show bgp summary'
```

The leaves and border1 carry four VRFs, one per tenant plus `external`, each as an L3VNI. The VRF routes travel as
EVPN type-5. border1 hands them to r5 over a VRF-lite link, and r5 sends a default back into every VRF:

```bash,run
docker exec leaf1 vtysh -c 'show evpn vni'
docker exec r5 vtysh -c 'show ip route bgp'
```

## The cluster

Three kind nodes. `bnk-worker` carries the TMM label; `bnk-worker2` carries the fake GPUs and the AI workloads.

```bash,run
kubectl get nodes -L app,workload -o wide
kubectl get nodes -o custom-columns='NODE:.metadata.name,HUGEPAGES:.status.allocatable.hugepages-2Mi,GPU:.status.allocatable.nvidia\.com/gpu'
```

`bnk-worker`'s `eth1` is a veth whose other end is `leaf1 eth3`. That is where TMM's external leg lives:

```bash,run
docker exec bnk-worker ip -br addr show eth1
docker exec leaf1 vtysh -c 'show bgp vrf all summary' | grep -E 'VRF|65100'
```

TMM speaks AS 65100. One session in the default domain (the shared VIP pool) and one in each tenant VRF (that
tenant's VIPs and its SNAT pool). The leaf answers as AS 65000, which is what TMM expects its gateway to be.

## BNK

```bash,run
kubectl -n f5-bnk get cneinstance,pods -o wide | head -40
kubectl -n f5-bnk get f5spkvlans,vrfs,routingconfigs,f5bnkgateways
```

## One request across all of it

The client sits behind r5, the way a user on the internet would. Aurora Health's first VIP lives in VRF tenant-a:

```bash,run
docker exec client curl -s -m 5 http://10.201.100.10/ | head -5
```

Trace it back: r5 learned `10.201.100.0/24` from border1, border1 learned it as a type-5 from leaf1, leaf1 learned
it over eBGP from TMM in VRF tenant-a, and TMM answered from Aurora's hello pods (`f5-bnk/tenant-a-hello`).

```bash,run
docker exec r5 vtysh -c 'show ip route 10.201.100.10'
docker exec leaf1 vtysh -c 'show bgp vrf tenant-a ipv4 unicast 10.201.100.10/32'
```

Open the **Polaris** tab: the AI Gateway console. The login is `admin`; the password is in the terminal:

```bash,run
kubectl -n f5-bnk get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d; echo
```

When the request above returns the hello page and the four TMM sessions on leaf1 are Established, click **Check**.
