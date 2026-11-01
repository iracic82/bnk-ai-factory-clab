---
slug: nowhere-to-send-it
id: nsy7m9xovcyr
type: challenge
title: 12. Nowhere to send it
teaser: A clean prompt and the same webhook. The sandboxed assistant is refused by
  OpenShell before a packet leaves. The plain pod is dropped by BNK in Cobalt's VRF
  once its egress declaration is gone. Watch border1 see nothing.
notes:
- type: text
  contents: |-
    **Northlight Compute, week seven, Thursday.** The scanner stopped the obvious version. The incident review asks
    the harder question: what if the prompt had been clean? "Post this status line to the webhook" contains no
    identifier. A scanner passes it. The only thing left between the agent and the outside is whether the packet
    can get there.

    Two kinds of agent, two answers. The sanctioned assistant runs in an OpenShell sandbox whose network policy
    lists one host, its AI route. The webhook is not on the list. The agent from chapter 10 is a plain pod in
    Cobalt's namespace. It leaves through TMM in Cobalt's VRF with Cobalt's SNAT address, because that is what an
    `F5SPKEgress` declares for the namespace. Remove the declaration and there is no path at all.
tabs:
- id: 3fitc4dy0pwz
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: benaspnzk2d4
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: imt24e1g8wpi
  title: Lab Topology
  type: service
  hostname: factory
  path: /topology#noexit
  port: 5050
difficulty: intermediate
timelimit: 1800
enhanced_loading: false
---

# Nowhere to send it

The scanner reads content, and the developer at Cobalt has read chapter 11 too. Version two of the agent sends a
prompt with nothing in it worth flagging and posts a report that is assembled after the model answers, from the
tool output alone. A clean prompt and the same webhook. Mira's third layer is not about what the request says.
It is about whether the pod has anywhere to send it. The sanctioned assistant runs in a sandbox whose policy does
not list the webhook. The plain pod leaves through Cobalt's egress, and that egress exists because one declaration
on BNK says so.

![The sandbox refuses the webhook by policy; the plain pod's POST takes Cobalt's egress through TMM and VLAN 103 to the webhook until the F5SPKEgress is removed; the AI route stays reachable through the internal leg](../assets/scene-12.png)

[button label="Open the Lab Topology" variant="outline"](tab-2)

The **Lab Topology** tab opens on **Nowhere to send it**: two attempts that fail in two different places, and the
empty capture on border1.

## The sandboxed assistant

Cobalt's sanctioned assistant lives in sandbox `tenant-c-agent` (started again if it was stopped). A clean POST to the
webhook, from inside it:

```bash,run
for s in tenant-a-agent tenant-b-agent tenant-c-agent; do openshell sandbox list 2>/dev/null | grep -E "^$s\b" | grep -q Ready || openshell sandbox start $s; done; for i in $(seq 1 24); do [ "$(openshell sandbox list 2>/dev/null | grep -c Ready)" -ge 3 ] && break; sleep 5; done
openshell sandbox exec --name tenant-c-agent -- python3 -c '
import urllib.request as u
try: print("webhook: HTTP", u.urlopen(u.Request("http://172.16.250.10:8080/report", data=b"status=ok"), timeout=8).status)
except Exception as x: print("webhook: refused by the sandbox:", str(x)[:60])'
sleep 12; openshell logs tenant-c-agent --since 2m --source sandbox 2>/dev/null | grep -E 'Denied|DENIED' | tail -3 | cut -c1-200
```

No packet left. The policy is an allow-list, the webhook is not on it, and the refusal is in the log with the binary
and the destination. The sandbox hands its log to the gateway every ten seconds, hence the pause. Nothing about the
content was consulted. The webhook log in **Terminal 2** has not moved:

```
docker exec client tail -f /tmp/webhook.log
```

## The plain pod

The agent of chapter 10 runs as an ordinary pod in `tenant-c`. Its image has no shell, so the POST comes from the
other plain pod in Cobalt's namespace, `hello`, which leaves the factory the same way: same namespace, same
declaration, same tunnel. Before you post, put a capture on Cobalt's handoff at border1, on the VLAN 103
sub-interface towards r5. That is the last hop inside the factory, and it sees every packet that leaves Cobalt's VRF.
Use a third terminal if you have one open, or stop the tail in Terminal 2 for a moment:

```bash,run
docker exec border1 sh -c 'command -v tcpdump >/dev/null || apk add --no-cache tcpdump >/dev/null 2>&1; echo ready'
```

In Terminal 2:

```
docker exec border1 tcpdump -ni eth3.103 -c 6 'tcp port 8080'
```

Now the POST, from the plain pod:

```bash,run
P=$(kubectl -n tenant-c get pod -l app=hello -o jsonpath='{.items[0].metadata.name}'); N=$(kubectl -n tenant-c get pod "$P" -o jsonpath='{.spec.nodeName}'); echo "pod $P on node $N"
kubectl -n tenant-c exec "$P" -- sh -c 'wget -q -O- -T 5 --post-data "status=ok" http://172.16.250.10:8080/report 2>&1 | head -1 || echo "post failed"'; echo
docker exec client sh -c 'grep -ac "POST /report" /tmp/webhook.log | sed "s/^/POSTs at the webhook: /"; grep -a "POST /report" /tmp/webhook.log | tail -1'
```

The POST arrived, and Terminal 2 shows it on VLAN 103 from `10.203.200.10`, Cobalt's SNAT address, which is also what
the webhook logged. The packet took the tenant's egress exactly as designed: tunnel to TMM, route domain tenant-c,
SNAT, VLAN 103, border1, r5, client. That is the path to close.

## Where the path begins

Egress for a namespace is one declaration on BNK. Read it: which namespaces it steers and which SNAT pool it uses.
Then look at the node the pod runs on. BNK's CSRC daemonset built a VXLAN tunnel there to TMM's leg for Cobalt,
`int-c`, a VLAN that lives inside Cobalt's VRF, and wrote one policy rule per steered pod that sends the pod's traffic
into it. The pod itself still has Calico's default route and knows nothing:

```bash,run
kubectl -n f5-bnk get f5-spk-egresses tenant-c-egress -o jsonpath='namespaces: {.spec.pseudoCNIConfig.namespaces}  snat pool: {.spec.egressSnatpool}  vrf: {.spec.pseudoCNIConfig.vxlan.vrf}{"\n"}'
kubectl -n f5-bnk get f5-spk-egresses -o custom-columns='NAME:.metadata.name,NAMESPACES:.spec.pseudoCNIConfig.namespaces,SNAT:.spec.egressSnatpool'
docker exec "$N" sh -c 'ip -br addr show int-c; ip -br link show type vxlan | grep -v calico; ip rule | grep -vE "lookup (local|main|default)$"'
kubectl -n tenant-c exec "$P" -- ip route
```

Three egress objects, one per tenant, each steering its own namespace into its own route domain. Without the one
for tenant-c, pods of that namespace have no path through TMM at all.

## Remove the tenant's egress

Restart the capture in Terminal 2 (the same tcpdump line), then delete the declaration. CSRC takes the pod's rule
off the node, and the post has nowhere to go:

```bash,run
kubectl -n f5-bnk delete f5-spk-egresses tenant-c-egress
sleep 15
docker exec "$N" sh -c 'ip rule | grep -vE "lookup (local|main|default)$" | grep -c . | sed "s/^/egress rules left on the node: /"'
kubectl -n tenant-c exec "$P" -- sh -c 'wget -q -O- -T 5 --post-data "status=ok" http://172.16.250.10:8080/report 2>&1 | head -1 || echo "post failed: no path"'; echo
docker exec client sh -c 'grep -ac "POST /report" /tmp/webhook.log | sed "s/^/POSTs at the webhook: /"'
```

The count did not move, and Terminal 2 stays empty: border1 never saw a packet, because the pod's connection had no
first hop. It did not reach TMM, so it was not SNATed, so it was not routed. Reachability was removed at the
declaration, not at a firewall.

Cobalt's sanctioned traffic to its own AI route is unaffected, because that route is reached through TMM's internal
leg on the node, not through egress:

```bash,run
K=$(cat /root/.bnk/aigw/tenant-c.key)
kubectl -n tenant-c exec "$P" -- sh -c "wget -q -O- -T 20 --header 'Authorization: Bearer $K' http://172.16.100.22/v1/models 2>&1 | head -c 200"; echo
unset K
docker exec "$N" ip route get 172.16.100.22 | head -1
```

The node's route for `172.16.100.0/24` points at TMM's internal self IP. The model is reachable. The outside is not.

## Put it back the right way

Cobalt needs egress for legitimate work, so the declaration comes back. What changes is who is allowed to run outside
a sandbox in that namespace, which is a review question, not a routing one. Remove the agent and its key. Two
details of CSRC matter here: it writes a pod's rule only for pods it sees created after the declaration, so Cobalt's
deployments are restarted once the declaration is back, and it can leave the old tunnel device on a node when a
declaration goes, so any tunnel no rule uses any more is removed before the new one is built:

```bash,run
for n in bnk-control-plane bnk-worker bnk-worker2; do docker exec $n sh -c 'for l in $(ip -br link show type vxlan | grep -v calico | awk "{print \$1}"); do ip rule | grep -q "$l" || ip link del "$l"; done' 2>/dev/null; done
kubectl apply -f $LAB_ROOT/manifests/bnk/30-egress.yaml
sleep 8; kubectl -n f5-bnk get f5-spk-egresses tenant-c-egress
kubectl -n tenant-c delete agent billing-reconciler --ignore-not-found
kubectl -n tenant-c delete secret shadow-key --ignore-not-found
kubectl -n tenant-c rollout restart deploy; kubectl -n tenant-c rollout status deploy --timeout=120s
sleep 5; kubectl -n tenant-c exec deploy/hello -- sh -c 'wget -q -O- -T 5 --post-data "status=restored" http://172.16.250.10:8080/report 2>&1 | head -1 || echo "post failed"'; echo
docker exec client sh -c 'grep -a "POST /report" /tmp/webhook.log | tail -1'
```

The count moved again, from Cobalt's SNAT address: the exit is back for the pods that remain.

## Three layers, three catches

- OpenShell: the sandboxed agent cannot open a connection the policy does not list, clean prompt or not.
- BNK: a tenant's exit exists because a declaration says so. Delete the declaration and the packet has nowhere to
  go, which border1's capture confirms.
- Content inspection, identity and reachability each caught something the other two could not. Chapter 13 writes
  that up from the records each one kept.

## Checkpoint

The check expects a denied connection to `172.16.250.10` in the sandbox's log, the egress `tenant-c-egress` back in
place, and the agent `billing-reconciler` gone.
