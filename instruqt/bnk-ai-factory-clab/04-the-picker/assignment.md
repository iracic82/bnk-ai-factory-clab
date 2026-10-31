---
slug: the-picker
id: ovove5gkzpwy
type: challenge
title: 4. The picker
teaser: BNK does not only pick a node; its Endpoint Picker chooses the model worker
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
    scrapes their `vllm:*` metrics, and scores every candidate on prefix-cache hits, prefill load, queue depth and
    KV usage before TMM forwards the request to the chosen worker.

    This is the layer the llm-d project calls "topology must reach the router". BNK's picker is cache- and
    load-aware; it does not yet score by network topology (rack, rail), which is what chapter 13 is about.
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
  path: /topology
  port: 5050
difficulty: intermediate
timelimit: 1200
enhanced_loading: false
---

![04-the-picker](../assets/04-the-picker.svg)

## The pool and its picker

```bash,run
kubectl -n aigw-models get inferencepool model-pool -o yaml | sed -n '/^spec:/,/^status:/p'
kubectl -n aigw-models get f5epp model-pool-epp -o jsonpath='{.spec.engine}{" "}{.spec.poolRef.name}{" "}{.status.conditions[-1].type}={.status.conditions[-1].status}{"\n"}'
kubectl -n aigw-models get cm model-pool-epp-config -o jsonpath='{.data.pool\.yaml}' | grep -E '^- name:|type:' | paste - - | column -t
```

The generated plugin list is the picker's scoring pipeline: `queue-scorer`, `f5-prefix-cache-scorer`,
`f5-prefill-load-scorer`, `f5-predictive-load-scorer`, `kv-cache-utilization-scorer`, `hcl-picker`.

## Watch a pick

The pool VIP is `172.16.100.12:8000`. Send one prompt, then the same prompt again, and read which worker the
picker named each time (the picker logs its choice; TMM forwards to exactly that pod):

```bash,run
P=$(kubectl -n aigw-models get pods -l app=model-pool-epp -o name 2>/dev/null | head -1); [ -n "$P" ] || P=$(kubectl -n aigw-models get pods -o name | grep epp | head -1)
ask() { docker exec client curl -s -m 60 http://172.16.100.12:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"Qwen/Qwen3-0.6B\",\"messages\":[{\"role\":\"user\",\"content\":\"$1\"}],\"max_tokens\":32}" | jq -r '.choices[0].message.content // .error' | head -c 120; echo; }
ask "Describe the water cycle in three sentences for a ten year old."
sleep 2
ask "Describe the water cycle in three sentences for a ten year old."
kubectl -n aigw-models logs $P --since=2m | grep -iE 'pick|select|endpoint' | tail -6
```

The second request has a prefix the first one already pushed into one worker's cache, so the prefix-cache scorer
pulls it to that worker. A different prompt is free to go to the other one:

```bash,run
ask "List four prime numbers above 100."
kubectl -n aigw-models logs $P --since=1m | grep -iE 'pick|select|endpoint' | tail -3
```

## Load-aware

Put one worker under load and the picker steers new requests to the other. Open the **Prometheus** tab and graph
`vllm:num_requests_running` while this runs:

```bash,run
for i in $(seq 1 12); do ask "Write a 200 word story about a lighthouse keeper, variation $i." >/dev/null & done; sleep 3
ask "What is the capital of Norway?"
wait
kubectl -n aigw-models logs $P --since=1m | grep -iE 'pick|select|endpoint' | tail -4
```

## Disaggregated mode

The `F5EPP` has a `mode` field: `aggregated` (every worker handles a request end to end, what runs here) or
`disaggregated` (the pool is split by label into prefill and decode workers, and the picker chooses one of each).
Read the field's description; it is the P/D contract chapter 13 compares with llm-d:

```bash,run
kubectl explain f5epp.spec.mode | sed -n '1,20p'
```

Click **Check** when the picker has logged at least one choice.
