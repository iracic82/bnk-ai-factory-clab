---
slug: a-model-you-dont-own
id: wkxptrz9xbim
type: challenge
title: 15. A model you don't own
teaser: Aurora rents a cloud model. A semantic router sends the hard prompts to Nova
  on Amazon Bedrock, the picker keeps the easy ones on the pool, and the only way
  out is one rule on Aurora's exit. Close it and only the cloud tier dies.
notes:
- type: text
  contents: |-
    **Northlight Compute, quarter's end.** Aurora's clinicians want discharge summaries, and the 0.6B model on the
    pool writes them badly. Northlight does not buy GPUs for one tenant's peak. It rents: Amazon Nova on Bedrock,
    paid per token, reached over the internet. Mira's condition for signing it off is one sentence. The model may
    live elsewhere, the exit stays Northlight's.

    Three pieces make that true. A semantic router on the lab route classifies each prompt and picks the model, so
    only the prompts that need the cloud go there. A proxy in Aurora's namespace is the only pod that speaks to AWS,
    and it leaves the factory through Aurora's egress like any other pod of that namespace. And one rule on Aurora's
    exit policy admits that traffic, logged, and can be flipped to reject on its own.

    If no AWS account is attached to this play, the router still runs and the cloud tier is off. The chapter says
    which case you are in.
tabs:
- id: pftpsekokdej
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: uz5wbro9jkjr
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: amciii4qadmj
  title: Lab Topology
  type: service
  hostname: factory
  path: /topology#cloud
  port: 5050
- id: kkuhpzk7zyaj
  title: Polaris
  type: service
  hostname: factory
  port: 3000
difficulty: intermediate
timelimit: 1800
enhanced_loading: false
---

# A model you don't own

Aurora wants a model Northlight cannot run on the pool. Mira rents one and keeps three things in Northlight's hands:
which prompts leave, which pod is allowed to send them, and whether the packet can leave at all. The router decides
the first, the namespace decides the second, and a rule on Aurora's exit decides the third. None of them is in the
picker's hands, because a cloud model has no worker to pick.

![The semantic router rewrites the model, the proxy in Aurora's namespace signs for Bedrock, and the request leaves through Aurora's egress under one rule on border1's VLAN 101](../assets/scene-15.png)

[button label="Open the Lab Topology" variant="outline"](tab-2)

The **Lab Topology** tab opens on **A model you don't own**: the request from the lab route to AWS, hop by hop.

## Is the cloud tier on

The proxy exists only when an AWS account came with the play. The router is always there:

```bash,run
kubectl -n tenant-a get secret bedrock-aws >/dev/null 2>&1 && echo "cloud tier: ON (an AWS account is attached to this play)" || echo "cloud tier: OFF (no AWS account on this play; the router runs, STEM prompts stay on the 1.5b CPU model)"
kubectl -n tenant-a get deploy,pdb,svc,pods -l app=bedrock-proxy -o wide 2>/dev/null
kubectl -n f5-bnk get sts,pdb,svc,pods -l app=semantic-router -o wide
kubectl -n f5-bnk get pvc -l app=semantic-router 2>/dev/null || kubectl -n f5-bnk get pvc | grep semantic-router
```

Two proxies behind one Service with a disruption budget, and two routers, each with its own 10 Gi volume. The volume
is where the router downloaded its classifier and its embedding model on first start, about 3.6 GB per pod, which
is why this chapter is last. If a router pod is not Ready yet, its log says how far the download is:

```bash,run
kubectl -n f5-bnk logs semantic-router-0 --tail=8 2>/dev/null | cut -c1-160
cat /var/log/setup-router-attach.log 2>/dev/null | tail -5
```

## The router on the profile

The router is an external processor on the lab tenant's AI Gateway profile. Polaris hands it every request body on
the lab route, and when the request names model `auto` the router answers with the model it chose. Read the hook on
the profile, the models the lab tenant publishes, and whether the profile is Programmed:

```bash,run
API=http://127.0.0.1:18443; NS=f5-bnk
TOK=$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)" "$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)" | curl -sS $API/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @- | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
curl -sS $API/api/v1/tenants/lab/profiles/lab-ai/semantic-router -H "Authorization: Bearer $TOK" | head -c 300; echo
curl -sS $API/api/v1/tenants/lab/models -H "Authorization: Bearer $TOK" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" models:", ", ".join(m.get("name","?") for m in (d.get("data") or d.get("items") or [])))'
curl -sS $API/api/v1/tenants/lab/provider-keys -H "Authorization: Bearer $TOK" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" providers:", ", ".join(p.get("name","?") for p in (d.get("data") or d.get("items") or [])))'
kubectl -n $NS get aigatewayprofiles.inference.k8s.f5.com lab-ai -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}' | sed 's/^/profile lab-ai Programmed: /'
unset TOK
```

The hook names the Service `semantic-router` on port 50051 with a one second budget. With the cloud tier on, the
provider list has `lab-bedrock` next to `lab-dynamo` and `lab-ollama`, and the models include `nova-micro`,
`nova-lite` and `nova-pro`. If the hook is empty, the attach has not run yet because the router was still
downloading. Run it by hand and wait for a Ready pod, up to ten minutes:

```bash,run
bash $LAB_ROOT/install/lib/attach-router.sh 600
```

## Three prompts, three answers

Ask the lab route three questions with model `auto`. The response's `model` field says where each one went:

```bash,run
K=$(cat /root/.bnk/aigw/lab.key)
ask() { docker exec client curl -sS -m 120 http://172.16.100.13/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":60}" | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("choices"); print(" model:", d.get("model"), "|", (c[0]["message"]["content"][:90].replace("\n"," ") if c else d.get("error")))'; }
ask "Write a four line poem about a night shift nurse."
ask "What is the time complexity of binary search, and why?"
ask "Reply with one word: ready."
unset K
```

The poem went to the small CPU model on ollama, the question about binary search to `nova-lite` on Bedrock (or to
the 1.5b CPU model when the cloud tier is off), and the one-word reply to the pool, where the picker chose the
worker as in chapter 4. The pool's answer reads as noise because the Mocker workers emit random tokens, as they
did in chapter 3. What matters is the `model` field. The router writes down every decision it makes, with the
signals that fired and the model it picked:

```bash,run
kubectl -n f5-bnk logs -l app=semantic-router --since 15m --tail=-1 2>/dev/null | grep -E 'routing_decision|ModelSelection' | tail -6 | python3 -c 'import sys,json; [print(" ", (lambda d: d.get("msg") if "ModelSelection" in d.get("msg","") else "decision: " + str(d.get("decision") or d.get("decision_name") or "?") + " -> " + str(d.get("selected_model") or d.get("model") or "?") + "  from model=" + str(d.get("original_model")))(json.loads(l))[:150]) for l in sys.stdin if l.strip().startswith("{")]'
```

With the cloud tier on, the proxy's log shows the Bedrock calls it signed:

```bash,run
kubectl -n tenant-a logs -l app=bedrock-proxy --since 1h --tail=-1 2>/dev/null | grep -iE 'nova|bedrock' | tail -4 | cut -c1-160
```

## The exit

The proxy is a pod in `tenant-a`, so its packets go where every pod of that namespace goes: into the tunnel to TMM,
route domain tenant-a, SNAT, VLAN 101. Chapter 12 showed that path for Cobalt. What is new is the first rule on
Aurora's policy: `cloud-tier` accepts TLS to port 443 and logs it, and it comes before `allow-all` so it can be
changed alone. Read the policy, then put a capture on Aurora's handoff at border1 and check that r5 has its NAT:

```bash,run
kubectl -n f5-bnk get f5-big-fw-policies egress-allow-a -o jsonpath='{range .spec.rule[*]}{.name}{"\t"}{.action}{"\t"}{.ipProtocol}{"\t"}ports={.destination.ports}{"\t"}logging={.logging}{"\n"}{end}'
kubectl -n f5-bnk get f5-spk-egresses tenant-a-egress -o jsonpath='namespaces: {.spec.pseudoCNIConfig.namespaces}  snat pool: {.spec.egressSnatpool}  policy: {.spec.firewallEnforcedPolicy}{"\n"}'
docker exec border1 sh -c 'command -v tcpdump >/dev/null || apk add --no-cache tcpdump >/dev/null 2>&1; echo border1: ready'
docker exec r5 sh -c 'iptables -t nat -S POSTROUTING 2>/dev/null | grep -c MASQUERADE | sed "s/^/r5 masquerade rules: /"'
```

In Terminal 2:

```
docker exec border1 tcpdump -ni eth3.101 -c 6 'tcp port 443'
```

Now a prompt that the router sends to the cloud:

```bash,run
K=$(cat /root/.bnk/aigw/lab.key)
docker exec client curl -sS -m 120 http://172.16.100.13/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"model":"auto","messages":[{"role":"user","content":"Explain why the sky is blue in two sentences."}],"max_tokens":60}' | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("choices"); print(" model:", d.get("model"), "|", (c[0]["message"]["content"][:120].replace("\n"," ") if c else d.get("error")))'
unset K
```

This one lands on `nova-pro`, because "explain why" is one of the reasoning keywords. Terminal 2 shows the TLS
handshake on VLAN 101 from `10.201.200.10`, Aurora's SNAT address, to an AWS address on port 443. The pod's address never appears, and neither does Northlight's. r5 masquerades on its way out, the way a
provider edge does. With the cloud tier off there is nothing to see on VLAN 101, and the answer came from the CPU
model.

## Close the cloud tier

Restart the capture in Terminal 2, then apply the closed version of Aurora's policy. Same name, same two rules, the
first one on reject:

```bash,run
cat $LAB_ROOT/manifests/chapters/15-cloud-closed-a.yaml
kubectl apply -f $LAB_ROOT/manifests/chapters/15-cloud-closed-a.yaml
sleep 5; kubectl -n f5-bnk get f5-big-fw-policies egress-allow-a -o jsonpath='{.spec.rule[0].name}: {.spec.rule[0].action}{"\n"}'
K=$(cat /root/.bnk/aigw/lab.key)
ask() { docker exec client curl -sS -m 120 http://172.16.100.13/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d "{\"model\":\"auto\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":60}" | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("choices"); print(" model:", d.get("model"), "|", (c[0]["message"]["content"][:90].replace("\n"," ") if c else str(d.get("error"))[:160]))'; }
ask "What is the time complexity of binary search, and why?"
ask "Write a four line poem about a night shift nurse."
unset K
```

The cloud prompt comes back as an error. The proxy's SYN to AWS was reset by TMM before SNAT and routing, LiteLLM
walked its ladder from `nova-lite` to `nova-micro` and found the same wall, and Terminal 2 stays empty. The poem
still answers, because the small model never leaves the factory. Aurora's other traffic matched `allow-all` all
along: nothing but TLS to the outside changed.

## Put it back

The policy opens again from the file that declared it:

```bash,run
kubectl apply -f $LAB_ROOT/manifests/bnk/30-egress.yaml
sleep 5; kubectl -n f5-bnk get f5-big-fw-policies egress-allow-a -o jsonpath='{.spec.rule[0].name}: {.spec.rule[0].action}{"\n"}'
K=$(cat /root/.bnk/aigw/lab.key)
docker exec client curl -sS -m 120 http://172.16.100.13/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"model":"auto","messages":[{"role":"user","content":"What is the time complexity of binary search, and why?"}],"max_tokens":60}' | python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("choices"); print(" model:", d.get("model"), "|", (c[0]["message"]["content"][:120].replace("\n"," ") if c else d.get("error")))'
unset K
```

## Two levers on one bill

- The router chooses the tier by what the prompt is. The picker chooses the worker by cache and load. They never
  overlap: Nova has no worker, no KV events and no metrics, so there is nothing for the picker to score, and the
  BNK team confirms the picker learns its workers from pods in its own cluster only.
- The exit policy says whether a packet leaves at all, and it changes in place. Reject resets the connection at
  TMM, before SNAT, before the fabric, before AWS.
- In a production cluster the same shape gets four more things: short-lived credentials instead of keys in a
  Secret, a destination by name in the rule (`destination.fqdns`, which needs TMM's FQDN resolver), a PrivateLink
  endpoint instead of the internet where the cluster has a path into AWS, and the router's models baked into an
  image instead of downloaded at start. `docs/cloud-tier.md` in the lab repository has the details.

## Checkpoint

The check expects Aurora's policy `egress-allow-a` with rule `cloud-tier` back at accept, the router StatefulSet
present, and, when the cloud tier is on, a Ready proxy that has signed at least one Nova request.
