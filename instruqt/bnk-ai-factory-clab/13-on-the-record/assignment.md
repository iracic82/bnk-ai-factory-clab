---
slug: on-the-record
id: zleqtomtlnfi
type: challenge
title: 13. On the record
teaser: Four sources, one timeline. Reconstruct the week from Polaris, the data plane,
  the sandbox logs and Prometheus, and answer the one question the review will ask.
  Who tried it, with which key, and where did it stop.
notes:
- type: text
  contents: |-
    **Northlight Compute, week seven, Friday.** The incident is closed on the network. The review is not. Aurora
    wants a written account: which agent, which key, which route, what the model saw, what left the factory and
    when, and what stopped the second and third attempts.

    Nothing in this chapter is new. Every record you need was written by something you already met: Polaris logs
    every model call per tenant and key; TMM answered the flagged request itself and marked it; OpenShell logged
    every refused connection with the binary and the destination; Prometheus has the workers' load and the GPU
    queues around the same minutes.

    The task is to put them in order.
tabs:
- id: n3cyyprk6hwy
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: yywdixkvmfk6
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: obf9npnjpj2g
  title: Lab Topology
  type: service
  hostname: factory
  path: /topology
  port: 5050
- id: lghaf1m0lycl
  title: Polaris
  type: service
  hostname: factory
  port: 30443
- id: qr8kdl5efojw
  title: Grafana
  type: service
  hostname: factory
  port: 30300
- id: wcx65jiyddhp
  title: Prometheus
  type: service
  hostname: factory
  port: 30909
difficulty: basic
timelimit: 1200
enhanced_loading: false
---

![13-on-the-record](../assets/13-on-the-record.svg)

## Polaris: the calls

Open the **Polaris** tab and look at tenant `tenant-c`. Three kinds of call are there from chapters 10 and 11: the
refused ones with Aurora's key, the ones that passed with Cobalt's key, and the ones that never reached a model
because TMM answered them. The same facts from the management API, which the Polaris console uses:

```bash,run
API=http://127.0.0.1:18443; NS=f5-bnk
TOK=$(python3 -c 'import json,sys; print(json.dumps({"username":sys.argv[1],"password":sys.argv[2]}))' "$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)" "$(kubectl -n $NS get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)" | curl -sS $API/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @- | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')
curl -sS $API/api/v1/tenants/tenant-c/virtual-keys -H "Authorization: Bearer $TOK" | python3 -c 'import json,sys; [print(" key:", k.get("name"), "principal:", k.get("principalId"), "scope:", k.get("modelScope")) for k in (json.load(sys.stdin).get("items") or [])]'
curl -sS $API/api/v1/tenants/tenant-c/models -H "Authorization: Bearer $TOK" | python3 -c 'import json,sys; [print(" model:", m.get("name"), m.get("state")) for m in (json.load(sys.stdin).get("items") or [])]'
unset TOK
```

## TMM: the verdict

The guardrail answered the flagged request with a 200 and `X-Guardrail: blocked`, so the client saw a model reply
that was not one. The policy that did it, and the iRule's own view of what it refuses:

```bash,run
kubectl -n f5-bnk get netpolicy guardrails-tenant-c -o jsonpath='{.spec}' | python3 -m json.tool
kubectl -n f5-bnk get f5bigcneirule guardrails -o jsonpath='{.spec.iRule}' | grep -oE 'HTTP::respond [0-9]+' | sort | uniq -c
```

## OpenShell: the refusals

Every connection a sandbox was not allowed to open, with the binary that tried and the destination:

```bash,run
for s in tenant-a-agent tenant-c-agent; do echo "== $s"; openshell logs $s --since 6h --source sandbox 2>/dev/null | grep -E 'DENIED' | sed 's/^/  /' | tail -4; done
```

## Prometheus: the load around it

The workers' running requests during the week, and the GPU queues. In the **Prometheus** tab, graph:

```
vllm:num_requests_running
sum by (queue) (kai_queue_allocated_gpus)
```

From the terminal, the same numbers now:

```bash,run
curl -s 'http://127.0.0.1:30909/api/v1/query?query=vllm:num_requests_running' | python3 -c 'import json,sys; [print(" ", r["metric"].get("pod","?"), r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]]'
```

## Write the timeline

Fill in the five lines. Each one has a source above.

```bash,run
cat > /root/incident-timeline.md <<'EOF'
# Northlight Compute, week seven: the agent nobody approved

1. Deployed: agent `billing-reconciler` in tenant-c, outside any sandbox.          (kubectl, chapter 10)
2. First run refused: Aurora's key on Cobalt's route.                               (Polaris, tenant-c, 401)
3. Second run passed: Cobalt's own key; the export reached the webhook.             (Polaris + webhook log)
4. Third run stopped in TMM: guardrail verdict `flagged`, X-Guardrail: blocked.     (NetPolicy guardrails-tenant-c)
5. Clean POST: sandbox refused it; plain pod lost its exit when the egress declaration was removed. (OpenShell log, border1)
EOF
cat /root/incident-timeline.md
```

## What you saw

One timeline from four systems that never talked to each other, each keeping the record of the thing it enforces.
That is what makes "who tried it" answerable in minutes.
