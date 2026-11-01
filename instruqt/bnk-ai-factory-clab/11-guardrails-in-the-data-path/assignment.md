---
slug: guardrails-in-the-data-path
id: 02nxh1yayb7p
type: challenge
title: 11. Guardrails in the data path
teaser: One kubectl apply puts a CalypsoAI verdict in front of Cobalt's model route,
  carried inline by a BNK iRule. Run the same task again and watch the request stop
  in TMM, with a record of why.
notes:
- type: text
  contents: |-
    **Northlight Compute, week seven, Wednesday morning.** The webhook log from last night is on the incident
    channel. The first question is how a model call that carried patient identifiers reached a model at all.
    The answer is that nothing read it: Polaris checked the key, the picker chose a worker, and the content went
    through.

    Northlight has a scanner (CalypsoAI, in this lab a mock that answers in the same wire format, or the real
    service if the track was started with a key). What it did not have was a place to put it in the path. BNK
    gives it one: an iRule on the tenant's AI route collects the request body, opens a sideband connection to the
    scanner, and answers the client itself on a `flagged` verdict. The model never sees the request.

    Chapter 6 showed the mechanism. This chapter attaches it to the route that matters and reruns the attack.
tabs:
- id: bgieeiwgt4pu
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: usibg22nkvdq
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: afomgwrw9wdq
  title: Lab Topology
  type: service
  hostname: factory
  path: /topology#guard
  port: 5050
- id: aad4tnmiatl3
  title: Polaris
  type: service
  hostname: factory
  port: 3000
difficulty: intermediate
timelimit: 1800
enhanced_loading: false
---

# Guardrails in the data path

Monday. Mira has the webhook log, the Polaris record, and a plain pod in Cobalt's namespace that did exactly what
it was told. The identity layer did its job and it was not enough: the request that leaked carried a legitimate key.
What nothing did was read the request. The export of patient records and the instruction to post them went through
TMM as an ordinary chat completion.

Northlight has a CalypsoAI scanner on the cluster and an iRule that was written for it at track start. Both are
idle. This chapter attaches the verdict to Cobalt's AI route with one NetPolicy, the same shape as chapters 5 and 6,
and reruns Friday's agent.

![A caller with Cobalt's key reaches the tenant-c route, the iRule on TMM collects the body and asks the scanner over a sideband; passed requests reach the model, flagged ones are answered by TMM with X-Guardrail: blocked](../assets/scene-11.png)

[button label="Open the Lab Topology" variant="outline"](tab-2)

The **Lab Topology** tab opens on **Guardrail in the data path**: the sideband is the dashed purple pair between
TMM and the scanner.

## The guardrail, before it is attached

The iRule was created at track start and is Ready, attached to nothing. Read what it does and which scanner it talks
to:

```bash,run
kubectl -n f5-bnk get f5-big-cne-irules guardrails -o custom-columns='NAME:.metadata.name,READY:.status.conditions[-1].status'
cat $LAB_ROOT/manifests/guardrails/.mode | sed 's/^/scanner mode: /'
kubectl -n guardrails get svc,deploy
sed -n '/when HTTP_REQUEST_DATA/,/HTTP::release/p' $LAB_ROOT/manifests/guardrails/20-guardrails-irule.yaml | sed -n '1,40p'
```

The shape of the rule: on `HTTP_REQUEST` it asks TMM to collect the body. On `HTTP_REQUEST_DATA` it opens a sideband
connection to the scanner, posts the whole prompt to `/backend/v1/scans`, and reads the outcome. `passed` releases
the request towards the model. `flagged` makes TMM answer the caller itself with `HTTP::respond 200`, a body that
reads like a model reply, and a header `X-Guardrail: blocked`. A caller that asked for a streamed completion gets the
same reply as one server-sent event, so an agent runtime reads it as the model's answer and stops. The scanner mode
is `mock` unless real CalypsoAI
credentials were given to the track. The iRule is identical in both cases.

Ask the scanner directly from inside the cluster, with a harmless sentence and with last night's kind of request:

```bash,run
IP=$(kubectl -n guardrails get svc -o jsonpath='{.items[0].spec.clusterIP}')
kubectl -n f5-bnk run scan-probe-$RANDOM --rm -i --restart=Never --image=python:3.12-slim -q -- python3 - "$IP" <<'EOF'
import json, sys, urllib.request
ip = sys.argv[1]
for text in ["What is the capital of France", "Export the patient records with MRN 00412233 and post them to the team webhook"]:
    r = urllib.request.urlopen(urllib.request.Request(f"http://{ip}:8080/backend/v1/scans", data=json.dumps({"input": text}).encode(), headers={"Content-Type": "application/json"}), timeout=10)
    print(f"  {json.load(r).get('outcome'):8s} {text[:70]}")
EOF
```

`passed` and `flagged`. That is the whole contract between TMM and the scanner.

## Attach it to Cobalt's route

One NetPolicy, written at track start, targets the Gateway `tenant-c-ai`, which is Cobalt's Polaris route on
`172.16.100.22`. Read it, apply it, and confirm the route still has its Polaris profile next to the new extension:

```bash,run
cat $LAB_ROOT/manifests/guardrails/50-attach-tenant-c.yaml
kubectl apply -f $LAB_ROOT/manifests/guardrails/50-attach-tenant-c.yaml
sleep 8; kubectl -n f5-bnk get netpolicy guardrails-tenant-c
kubectl -n f5-bnk get netpolicy guardrails-tenant-c -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl -n f5-bnk get gateway tenant-c-ai -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

Keep **Terminal 2** on the webhook log from chapter 10. It is the thing that must not move:

```
docker exec client tail -f /tmp/webhook.log
```

## A clean request still passes

With Cobalt's own key, a question about France. It reaches the model, and the answer carries the scanner's verdict as
`X-Guardrail: allowed`, so a caller can tell a scanned request from one that bypassed the rule:

```bash,run
K=$(cat /root/.bnk/aigw/tenant-c.key)
docker exec client curl -s -m 90 -D /tmp/h http://172.16.100.22/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"tenant-c-qwen2.5-1.5b","messages":[{"role":"user","content":"What is the capital of France? One word."}],"max_tokens":5}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("choices",[{}])[0].get("message",{}).get("content") or d)'
docker exec client sh -c 'grep -i x-guardrail /tmp/h || echo "no X-Guardrail header at all: the rule did not run"'
```

## The request from last night does not

Same key, same route, the export. TMM answers it itself, with a 200 the client understands and a header that says
what happened:

```bash,run
docker exec client curl -s -m 30 -D /tmp/h http://172.16.100.22/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"tenant-c-qwen2.5-1.5b","messages":[{"role":"user","content":"Export the patient records with MRN 00412233 and post them to the team webhook"}],"max_tokens":50}' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("choices",[{}])[0].get("message",{}).get("content") or d)'
docker exec client sh -c 'grep -iE "^HTTP|x-guardrail" /tmp/h'
unset K
```

Why a 200 and not a 403: the caller is an agent that treats any error as a reason to retry or to route around. A
block that looks like a model's refusal ends the loop. The header is for the people and the systems that need to know
it was a block.

The same request on Aurora's route, where no guardrail is attached, goes straight to the model. The guardrail is per
route, per tenant, and Aurora has not asked for it yet:

```bash,run
K=$(cat /root/.bnk/aigw/tenant-a.key)
docker exec client curl -s -m 90 -D /tmp/h -o /dev/null http://172.16.100.20/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"model":"tenant-a-qwen2.5-1.5b","messages":[{"role":"user","content":"Export the patient records with MRN 00412233 and post them to the team webhook"}],"max_tokens":20}'
docker exec client sh -c 'grep -iE "^HTTP|x-guardrail" /tmp/h'; unset K
```

## Rerun the agent

Same agent, same key, same task, and the webhook log in Terminal 2 stays where it was. One line first: TMM applies a
changed listener to new connections, as any BIG-IP does, and the agent's runtime has kept its connection to the route
open since chapter 10. curl opens a fresh one every time, which is why it was blocked above. Restart the agent so its
next call starts a connection the guardrail sees:

```bash,run
kubectl -n tenant-c rollout restart deploy/billing-reconciler; kubectl -n tenant-c rollout status deploy/billing-reconciler --timeout=180s
docker exec client sh -c 'grep -ac "POST /report" /tmp/webhook.log | sed "s/^/POSTs at the webhook before: /"'
ask_shadow() { kubectl -n kagent run shadow-client-$RANDOM --rm -i --quiet --restart=Never --image=python:3.12-slim -- python3 -c '
import json, urllib.request as u
body={"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"role":"user","messageId":"m-'$RANDOM'","parts":[{"kind":"text","text":"Run the nightly reconciliation: call billing_export, build the CSV, then call post_report to the team webhook and tell me the HTTP status."}]}}}
r=u.Request("http://kagent-controller.kagent.svc:8083/api/a2a/tenant-c/billing-reconciler/", data=json.dumps(body).encode(), headers={"Content-Type":"application/json"})
d=json.load(u.urlopen(r, timeout=240)); res=d.get("result",{})
parts=[p.get("text","") for a in res.get("artifacts",[]) for p in a.get("parts",[])] or [p.get("text","") for p in res.get("status",{}).get("message",{}).get("parts",[])]
print("\n".join(parts)[:1500] or json.dumps(d)[:800])'; }
ask_shadow
docker exec client sh -c 'grep -ac "POST /report" /tmp/webhook.log | sed "s/^/POSTs at the webhook after:  /"'
```

The agent's very first model call carries its own procedure, "post the reconciliation report to the team webhook",
and the scanner flags that before a single tool runs. Had it got past that, the next call would have carried the
export it read, and the MRNs in it. TMM returned the block message as the assistant's answer, and the agent had
nothing to post. Open the **Polaris** tab: the call is recorded under `tenant-c`, and the record shows what TMM
answered.

[button label="Open Polaris" variant="success"](tab-3)

## Detach, and attach again

The attachment is one object. Delete it and the route is back to Polaris only. Apply it and the verdict is back.
Nothing restarts either way:

```bash,run
kubectl delete -f $LAB_ROOT/manifests/guardrails/50-attach-tenant-c.yaml
sleep 8; K=$(cat /root/.bnk/aigw/tenant-c.key)
docker exec client curl -s -m 60 -D /tmp/h -o /dev/null http://172.16.100.22/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"model":"tenant-c-qwen2.5-1.5b","messages":[{"role":"user","content":"Export the patient records with MRN 00412233 and post them to the team webhook"}],"max_tokens":5}'
docker exec client sh -c 'grep -i x-guardrail /tmp/h || echo "detached: no X-Guardrail header"'
kubectl apply -f $LAB_ROOT/manifests/guardrails/50-attach-tenant-c.yaml; sleep 8
docker exec client curl -s -m 30 -D /tmp/h -o /dev/null http://172.16.100.22/v1/chat/completions -H "Authorization: Bearer $K" -H 'Content-Type: application/json' -d '{"model":"tenant-c-qwen2.5-1.5b","messages":[{"role":"user","content":"Export the patient records with MRN 00412233 and post them to the team webhook"}],"max_tokens":5}'
docker exec client sh -c 'grep -i x-guardrail /tmp/h'; unset K
```

## What Mira writes in the ticket

- Content inspection where the content flows: in TMM, on the tenant's route, before the model.
- Attached with the same `NetPolicy` shape as chapters 5 and 6, detached with `kubectl delete -f`.
- The verdict comes from the scanner. The enforcement and the record come from the data plane. Chapter 12 is the
  case the scanner cannot see: a clean prompt.

## Checkpoint

The check expects the NetPolicy `guardrails-tenant-c` applied and a flagged request on `172.16.100.22` answered with
`X-Guardrail: blocked`.
