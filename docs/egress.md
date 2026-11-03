# Tenant egress on kind: how the tunnel is built here

Egress is the one BNK feature that reaches into the nodes. A daemonset, CSRC, builds a VXLAN tunnel on every node
to TMM and writes one policy rule per steered pod. TMM takes the pod's packet out of its tunnel, applies the
tenant's SNAT address and routes it out of the tenant's VRF. On the EVE lab that just worked, because the nodes
were VMs with real NICs on a network the fabric could route to. On this VM the nodes are containers on a private
docker network, and four assumptions failed, one behind the other. I found them in play 6 (2026-11-01), each with
a capture, and the install now carries the answer to each.

```
 pod 192.168.x.y (tenant-c)                       TMM (bnk-worker)                      fabric
 ──────────────────────────                       ────────────────                      ──────
 cali veth ─► node ip rule "from pod" ─► vxlan1NN ──► int-c  VLAN 203, VRF tenant-c ──► egress listener
              table: default via 10.0.128.1         (10.249.3.250)                      SNAT 10.203.200.10
              local 10.249.3.24x dev int-c                                              route: default via leaf1
              (VLAN sub-interface of eth0)                                              fab-c VLAN 103 ─► border1 ─► r5 ─► client
```

## What had to change

1. **CSRC sees no veth.** It reports a node's physical, vlan, macvlan and vxlan devices and lo. A kind node has
   only veths, so the controller found no interface in the tunnel subnet and built nothing. F5's own BNK-on-kind
   lab gives every node docker macvlan legs for the same reason. Here each node gets VLAN sub-interfaces of eth0
   named `int-a`, `int-b`, `int-c` (tags 201 to 203, addresses 10.249.1-3.241 to .243). The names avoid "eth0" on
   purpose: Calico's interface setting is the regular expression `eth0`, and an `eth0.203` made Calico move its own
   VXLAN endpoint onto the tenant leg.
2. **The tunnel must live in the tenant's VRF end to end.** The controller programs the tunnel's remote endpoints
   (the node VTEPs) in the VRF of the F5SPKEgress. With the underlay on TMM's internal VLAN in route domain 0, TMM
   looked the nodes up inside the tenant VRF, where the only route is the default towards the fabric. EVE's fabric
   happened to route back to the node network. So each tenant has its own leg on TMM's internal interface: an
   F5SPKVlan `int-a/b/c` tagged 201 to 203, `vrf: tenant-x`, `internal: true`, self IP 10.249.x.250, and the egress
   names it as `tmmInterfaceName`. Calico's felix lists those three addresses as external nodes next to the
   internal self IP, or it drops their VXLAN.
3. **The firewall.** This instance runs with the AFM firewall ACL on, and an egress listener under AFM forwards only
   with an enforced policy. One accept-all `F5BigFwPolicy` per tenant, `egress-allow-a/b/c`, each named by that
   tenant's egress object. I verified enforcement by switching one to reject: the pod got a reset at once, and the
   capture on border1 stayed empty. Chapter 12 is built on that: it closes Cobalt's exit by applying the reject
   version of `egress-allow-c` and opens it again by applying `30-egress.yaml`.
4. **Checksums.** A pod's TCP checksum is left for hardware to fill, and on a veth nothing fills it. The kernel and
   Calico never notice. TMM validates the checksum of what it takes out of the tunnel and drops the SYN after the
   listener has matched it: 14 connections, no server side, no counter, no log. F5's kind lab turns
   `tx-checksum-ip-generic` off on the egress vxlan devices after creating the egress objects. CSRC recreates
   those devices whenever an egress is declared again, and the leg interfaces report the feature
   as fixed, so a small watcher container per node (`csum-<node>`, the netshoot image the lab already has, in the
   node's network namespace with NET_ADMIN) keeps every CSRC vxlan device at checksum-off.

One more consequence: once egress steers a namespace, everything a pod sends that is not excluded goes into the
tunnel, including calls to its own AI route on 172.16.100.x. Those are meant to reach TMM through the node's route
to the internal self IP, which is what chapter 12 says and chapters 7 to 9 rely on, so the VIP network is in
CSRC's `EXCLUDE_CIDR` with the pod, service and node networks.

## How setup proves it

The last step of `install/35-bnk-network.sh` starts the webhook receiver on the client, lists the CSRC daemonset,
prints each node's tunnels and policy rules, and sends `GET /probe` from tenant-c's hello pod. The webhook log line
it prints shows the request arriving from `10.203.200.10`, Cobalt's SNAT address. On failure it prints CSRC's log,
the controller's tunnel data and felix's settings, which is how play 6 was read.

## Where the facts came from

- `kubectl -n f5-cne-core logs ds/f5-spk-csrc -c spk-csrc`: `NodeNetworkInterfaces response` (what CSRC reports),
  `CreateAndUpdateVxlanData` (what the controller sent back).
- `kubectl -n f5-bnk logs deploy/f5-cne-controller -c f5-cne-controller`: the `declTmm.vxlan`, `l2_forward` and
  `virtual_server` messages, with the route domain of every address.
- In TMM's debug container: `tcpdump -nnei 0.0`, `tmctl -d blade -i virtual_server_stat`, `fw_rule_stat`.

## Why chapter 12 never deletes an egress

The first version of chapter 12 removed Cobalt's exit by deleting `tenant-c-egress` and put it back by applying the
file again. On the cold build of play 8 (2026-11-02) that left Cobalt without a tunnel and then took Aurora's away
too, and the controller log shows how:

- A recreated egress does not relearn the pods of its namespace. The controller's count of steered pods for the new
  object starts at zero, every pod it then sees arrive is logged as "unexpected object", and every pod that
  terminates still counts down.
- On the next rollout of the tenant's deployments the count reaches zero, and at zero the controller sends CSRC a
  mapping delete for the egress, `tmmCnfMapsDel`, with an empty tunnel name.
- CSRC's delete handler walks every route table it has and removed `vxlan100`, Aurora's device, on all three nodes.
  A CSRC restart rebuilt Aurora and Borealis from the controller's memory and nothing for Cobalt.

A controller restart is the one thing that would rebuild that memory, and rule 6 of the lifecycle notes rules it out
on this build. So the egress objects are created once at setup and never touched again. What chapter 12 changes is
the firewall policy the egress names, which TMM applies to new connections in place: reject resets the pod's SYN
before SNAT and routing, accept lets it through, and neither touches CSRC, the tunnels or the pod rules.

```
pod ──veth──▶ vxlanNNN ──▶ TMM egress listener (tenant-c)
                              │ policy egress-allow-c
                              ├─ accept: SNAT 10.203.200.10 ─▶ VLAN 103 ─▶ border1 ─▶ r5 ─▶ webhook
                              └─ reject: RST back to the pod, nothing on VLAN 103
```

## The cloud tier's way out (chapter 15, 2026-11-03)

Aurora's exit carries the one thing in this lab that talks to the internet: the Bedrock proxy in `tenant-a`
(`manifests/ai/60-bedrock-proxy.yaml`). It takes the same path as any pod of the namespace, and two things were
added so that the path reaches AWS and can be closed on its own.

The policy `egress-allow-a` has two rules in order. `cloud-tier` accepts tcp/443 and logs it, `allow-all` keeps
Aurora's other traffic as it was. Chapter 15 flips the first rule to reject (`manifests/chapters/15-cloud-closed-a.yaml`)
and opens it again from `30-egress.yaml`, the way chapter 12 does for Cobalt. The 2.4.2 CRD also takes
`destination.fqdns`. A name in a rule needs TMM's global FQDN resolver, and the installer creates it
(`manifests/bnk/35-fqdn-resolver.yaml`: an `F5BigDnsCache` named `security-fqdn-dns-resolver`, zone `amazonaws.com`,
two public nameservers reached through the external leg and r5). Chapter 15 then swaps the port rule for
`manifests/chapters/15-cloud-by-name-a.yaml`, which admits `bedrock-runtime.us-east-1.amazonaws.com` on 443 and
rejects every other TLS destination before `allow-all`, and reads `fw_fqdn_stat` on TMM for the resolutions. The
port rule stays the install-time baseline and the fallback.

r5 masquerades. A packet for an address outside the factory leaves r5 on its management interface, where docker's
own NAT only translates docker's subnet. One POSTROUTING rule on r5's eth0 keeps Aurora's SNAT address inside, and
the reply finds its way back through r5, border1, leaf1 and TMM. The FRR image carries no iptables: `fabric/nodes/r5/setup.sh`
asks apk for it at boot, and `install/10-fabric.sh` repeats that with retries after the deploy, because on the first
play the management network was not up yet when the setup script ran.

```
bedrock-proxy pod ──veth──▶ vxlan100 ──▶ TMM egress listener (tenant-a)
                                           │ policy egress-allow-a
                                           ├─ rule cloud-tier (tcp/443, logged)
                                           │    ├─ accept: SNAT 10.201.200.10 ─▶ VLAN 101 ─▶ border1 ─▶ r5 ─MASQUERADE─▶ bedrock-runtime.us-east-1.amazonaws.com:443
                                           │    └─ reject: RST to the proxy; LiteLLM reports the model as unreachable, the local models go on answering
                                           └─ rule allow-all: everything else Aurora sends, unchanged
```
