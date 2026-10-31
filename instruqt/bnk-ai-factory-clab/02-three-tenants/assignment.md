---
slug: three-tenants
id: ""
type: challenge
title: 2. Three tenants
teaser: Aurora Health, Borealis Bank and Cobalt Labs each get a VRF on the fabric, a VLAN leg into TMM, their own VIPs,
  their own egress addresses and their own AI Gateway tenant. Read one tenant end to end, then publish a new service
  for another and watch the fabric carry it.
notes:
- type: text
  contents: |-
    A tenant in this factory is declared, not configured by hand, and the declaration spans every layer:

    - on the fabric: a VRF with an L3VNI on leaf1 and border1, a VLAN leg on the leaf's handoff port, an eBGP
      session to TMM inside the VRF, and a VRF-lite link to r5
    - on BNK: a `Vrf` (route domain), an `F5SPKVlan` leg, a `RoutingConfig` that renders the VRF's BGP into OcNOS,
      `F5VirtualServer`s in the VRF, and an `F5SPKEgress` with the tenant's own SNAT pool
    - on Kubernetes: the namespace, a NetworkPolicy, and the tenant's own AI Gateway tenant with its own virtual key

    The point of this chapter is that nothing a tenant has can be reached by another tenant, and that the fabric
    treats each one as its own routing domain all the way to r5.
tabs:
- id: terminal
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: polaris
  title: Polaris
  type: service
  hostname: factory
  port: 30443
difficulty: basic
timelimit: 1200
enhanced_loading: false
---

## One tenant, every layer

Aurora Health is `tenant-a`. Its declaration on BNK:

```bash,run
kubectl -n f5-bnk get vrf tenant-a f5spkvlan fab-a routingconfig tenant-a f5virtualserver tenant-a-vip f5spkegress tenant-a-egress f5spksnatpool tenant-a-snat
cat $LAB_ROOT/manifests/bnk/40-tenants.yaml | sed -n '/name: tenant-a/,/snat: {type: automap}/p'
```

The same tenant on the fabric. leaf1 peers with TMM inside VRF tenant-a over VLAN 101 and accepts exactly two
things from it: the tenant's VIP pool and its SNAT pool.

```bash,run
docker exec leaf1 vtysh -c 'show bgp vrf tenant-a summary'
docker exec leaf1 vtysh -c 'show ip bgp vrf tenant-a'
docker exec leaf1 vtysh -c 'show running-config' | grep -A3 'prefix-list from-tmm-tenant-a'
```

And on r5, which sees the tenant through border1's VRF-lite link:

```bash,run
docker exec r5 vtysh -c 'show ip bgp neighbors 172.16.201.1 routes' | grep -E '^\*|Network'
```

## Isolation

The client reaches Aurora's VIP through r5. Aurora's hello pod cannot reach Cobalt's, and nothing in tenant-c can
open a connection into tenant-a:

```bash,run
docker exec client curl -s -m 5 http://10.201.100.10/ | head -3
kubectl -n tenant-c exec deploy/hello -- sh -c 'wget -q -O- -T 3 http://hello.tenant-a.svc.cluster.local/ 2>&1 | head -2 || echo "tenant-c -> tenant-a: refused"'
```

Where a tenant's pods go when they leave: through TMM in the tenant's VRF, with the tenant's SNAT address. r5 sees
`10.201.200.10` for Aurora, never a pod address:

```bash,run
kubectl -n tenant-a exec deploy/hello -- sh -c 'wget -q -O- -T 5 http://172.16.250.10/ >/dev/null 2>&1; echo "left the factory: $?"'
docker exec r5 vtysh -c 'show ip route 10.201.200.0/24'
```

## Publish a second service for Borealis Bank

Borealis is `tenant-b`. Add a VIP in its VRF in front of its hello app, on `10.202.100.11`. The pool already exists
(`tenant-b-hello`); you add the `F5VirtualServer`:

```bash,run
cat <<'EOF' | kubectl apply -f -
apiVersion: k8s.f5net.com/v1
kind: F5VirtualServer
metadata: {name: tenant-b-reports, namespace: f5-bnk}
spec:
  destinationAddress: 10.202.100.11
  destinationPort: 80
  vrf: tenant-b
  pool: tenant-b-hello
  routeAdvertisement: true
  snat: {type: automap}
EOF
```

Within a few seconds TMM announces the /32 to leaf1 inside VRF tenant-b, leaf1 exports it as an EVPN type-5,
border1 passes it to r5, and the client can call it:

```bash,run
sleep 10
docker exec leaf1 vtysh -c 'show ip bgp vrf tenant-b 10.202.100.11/32'
docker exec r5 vtysh -c 'show ip route 10.202.100.11'
docker exec client curl -s -m 5 -o /dev/null -w 'client -> 10.202.100.11: HTTP %{http_code}\n' http://10.202.100.11/
```

## The tenant's AI Gateway tenant

Each tenant has its own tenant in Polaris, with its own route on its own VIP and its own virtual key. Open the
**Polaris** tab and look at tenants `tenant-a`, `tenant-b`, `tenant-c`: providers, models, keys, routes. From the
terminal, a request through Borealis's route with Borealis's key:

```bash,run
K=$(cat /root/.bnk/aigw/tenant-b.key)
docker exec client curl -s -m 120 http://172.16.100.21/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-1.5b","messages":[{"role":"user","content":"In one sentence, what is a VRF?"}],"max_tokens":60}' | jq -r '.choices[0].message.content'
```

The same key on Aurora's route is refused: keys belong to a tenant.

```bash,run
docker exec client curl -s -m 20 http://172.16.100.20/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-1.5b","messages":[{"role":"user","content":"hi"}]}' | jq -c '{error: (.error.message // .error // "none")}'
```

Click **Check** when the client reaches `10.202.100.11`.
