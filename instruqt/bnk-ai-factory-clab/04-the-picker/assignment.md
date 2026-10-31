---
slug: the-picker
id: ovove5gkzpwy
type: challenge
title: 4. The picker
teaser: BNK does not only pick a node. Its Endpoint Picker chooses the model worker
  per request, from the workers' own KV-cache events and load. Send the same prompt
  twice and watch the second one land where the cache is.
notes:
- type: text
  contents: |-
    **Northlight Compute, week two, day four.** Borealis asks why two identical requests cost different amounts of
    time. The answer lives one layer below the gateway: the picker that chooses a worker per request from the
    workers' own cache state and load. Northlight shows them the decision being made.

    The Gateway API Inference Extension puts an **Endpoint Picker** between the gateway and the model pool. F5's
    picker (`F5EPP`) runs with the engine set to `dynamo`: it subscribes to the workers' KV-cache events on NATS,
    scrapes their `dynamo_component_*` metrics, and scores every candidate on prefix-cache hits, prefill load, queue depth and
    KV usage before TMM forwards the request to the chosen worker.

    This is the layer the llm-d project calls "topology must reach the router". BNK's picker is cache- and
    load-aware. It does not yet score by network topology (rack, rail), which is what chapter 13 is about.
tabs:
- id: megyxgnorev5
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: vuwchtju0cez
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: vcwo6kuwrxk3
  title: Prometheus
  type: service
  hostname: factory
  port: 30909
- id: ghsz302wuuku
  title: Grafana
  type: service
  hostname: factory
  port: 30300
- id: 4r1ciir4kaic
  title: Lab Topology
  type: service
  hostname: factory
  path: /topology#picker
  port: 5050
difficulty: intermediate
timelimit: 1500
enhanced_loading: false
---

# The picker

Aurora's clinical assistant is in pilot and its prompts share a long system prefix. Every time one of those prompts
lands on a worker that has never seen the prefix, the worker has to prefill it from scratch, and the customer
notices the pause. The engineer who runs the models asks Mira a question load balancers usually cannot answer:
"Can the gateway send the request to the worker that already has the cache?" In this factory it can. The pool VIP's
route does not end in a Service. It ends in an `InferencePool`, and for every request TMM asks F5's Endpoint Picker
which worker should take it.

![The client calls the pool VIP, TMM asks the F5EPP picker which worker should take the prompt, the picker answers from KV-cache state on NATS and load, and TMM forwards to exactly that mocker](../assets/scene-04.png)

[button label="Open the Lab Topology" variant="outline"](tab-4)

The **Lab Topology** tab opens on **The pool VIP and the picker**: three hops, with the question and the answer drawn
as the dashed line between TMM and the picker.

## The pool and its picker

Three objects. An `InferencePool` that selects the worker pods, an `F5EPP` that runs the picker for it, and the
ConfigMap the picker generated with its scoring pipeline:

```bash,run
kubectl -n aigw-models get inferencepool model-pool -o yaml | sed -n '/^spec:/,/^status:/p'
kubectl -n aigw-models get f5-epps model-pool-epp -o jsonpath='{.spec.engine}{" "}{.spec.poolRef.name}{" "}{.status.conditions[-1].type}={.status.conditions[-1].status}{"\n"}'
kubectl -n aigw-models get cm model-pool-epp-config -o jsonpath='{.data.pool\.yaml}' | grep -E '^- name:|type:' | paste - - | column -t
```

The plugin list is the pipeline: `queue-scorer`, `f5-prefix-cache-scorer`, `f5-prefill-load-scorer`,
`f5-predictive-load-scorer`, `kv-cache-utilization-scorer`, and `hcl-picker`, which turns the scores into one name.
The engine is `dynamo`, which means the prefix-cache scorer is fed by KV events the workers publish on NATS, not by
guessing from request history:

```bash,run
kubectl -n aigw-models get f5-epps model-pool-epp -o jsonpath='{.spec.natsURL}{"\n"}'
kubectl -n aigw-models get pods -o wide --no-headers | awk '{printf "%-44s %-10s %s\n", $1, $3, $7}'
```

And the route that puts the picker in the path. The pool VIP is `172.16.100.12:8000`, a BNK Gateway with an
HTTPRoute whose backend is the InferencePool:

```bash,run
kubectl -n aigw-models get gateway,httproute
kubectl -n aigw-models get httproute -o jsonpath='{range .items[*]}{.metadata.name}: {range .spec.rules[*].backendRefs[*]}{.kind}/{.name} {end}{"\n"}{end}'
```

## Watch a pick

Send one prompt, then the same prompt again, and read which worker the picker named each time. Put **Terminal 2** on
the picker's log so you see the choices as they happen:

```
P=$(kubectl -n aigw-models get pods -o name | grep epp | head -1); kubectl -n aigw-models logs -f $P | grep -iE 'pick|select|endpoint'
```

Here, the helper `ask` sends one chat request through the pool VIP and prints the first line of the answer:

```bash,run
P=$(kubectl -n aigw-models get pods -l app=model-pool-epp -o name 2>/dev/null | head -1); [ -n "$P" ] || P=$(kubectl -n aigw-models get pods -o name | grep epp | head -1)
ask() { docker exec client curl -s -m 60 http://172.16.100.12:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"Qwen/Qwen3-0.6B\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":32}" | jq -r '.choices[0].message.content // .error' | head -c 120; echo; }
ask "Describe the water cycle in three sentences for a ten year old."
sleep 2
ask "Describe the water cycle in three sentences for a ten year old."
kubectl -n aigw-models logs $P --since=2m | grep -iE 'pick|select|endpoint' | tail -6
```

The second request has a prefix the first one pushed into one worker's KV cache, so the prefix-cache scorer pulls it
to that worker. A different prompt has no such pull and is free to go to the other one:

```bash,run
ask "List four prime numbers above 100."
kubectl -n aigw-models logs $P --since=1m | grep -iE 'pick|select|endpoint' | tail -3
```

This is the answer to Aurora's engineer. The gateway did not hash on a header or round-robin. It asked.

## Load-aware

Cache is one signal. Load is the other. Put one worker under load with a burst of long prompts and send a short one
behind them. Open the **Prometheus** tab and graph `dynamo_component_inflight_requests` while this runs:

[button label="Open Prometheus" variant="success"](tab-2)

```bash,run
for i in $(seq 1 12); do ask "Write a 200 word story about a lighthouse keeper, variation $i." >/dev/null & done; sleep 3
ask "What is the capital of Norway?"
wait
kubectl -n aigw-models logs $P --since=1m | grep -iE 'pick|select|endpoint' | tail -4
curl -s 'http://127.0.0.1:30909/api/v1/query?query=dynamo_component_inflight_requests' | python3 -c 'import json,sys; [print(" ", r["metric"].get("pod","?"), r["value"][1]) for r in json.load(sys.stdin)["data"]["result"]]'
```

The short question went to the less loaded worker even though neither had its prefix. The prefill-load and queue
scorers outweighed the cache scorer, which had nothing to say.

## TMM's side of it

The ext-proc conversation is invisible to the client. From TMM's point of view the pool VIP is a virtual server
whose pool members are chosen per request, and the picker's answer is honoured exactly. Read the virtual server BNK
built for the route and the pool behind it:

```bash,run
kubectl -n f5-bnk get f5-virtualservers,pools -A --no-headers 2>/dev/null | grep -iE 'model-pool|aigw-models' | head -6
kubectl -n aigw-models get inferencepool model-pool -o jsonpath='{.status}' | python3 -m json.tool | head -20
```

## Disaggregated mode

The `F5EPP` has a `mode` field: `aggregated`, where every worker handles a request end to end, which is what runs
here, or `disaggregated`, where the pool is split by label into prefill and decode workers and the picker chooses one
of each. Read the field's description now. Chapter 14 comes back to it when the question is whether the picker knows
where a worker sits:

```bash,run
kubectl explain f5-epps.spec.mode | sed -n '1,20p'
```

## Checkpoint

The check sends one request through the pool VIP and expects a 200, and expects the picker to have logged at least
one choice in the last thirty minutes.
