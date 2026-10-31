# Storyline: the factory, three tenants, and the shadow agent

An AI factory operator rents GPU capacity to three tenants. Each tenant gets its own network (a VRF on the
fabric, a VLAN leg into TMM, its own VIPs), its own AI Gateway tenant in the Polaris console with its own
models and virtual keys, and its own kagent agents with a fixed set of tools. The operator's promise is that
nothing a tenant does can touch another tenant, and that nothing an agent does leaves the factory unseen.

| Tenant | Namespace | Who they are | VRF / L3VNI | TMM VLAN | VIPs |
|---|---|---|---|---|---|
| Aurora Health | `tenant-a` | clinical data, PII everywhere | tenant-a / 10001 | 101 | 10.201.100.0/24 |
| Borealis Bank | `tenant-b` | payments, strict egress | tenant-b / 10002 | 102 | 10.202.100.0/24 |
| Cobalt Labs | `tenant-c` | research team, moves fast, spins up agents | tenant-c / 10003 | 103 | 10.203.100.0/24 |

The antagonist is not an attacker from outside. It is a developer at Cobalt Labs who deploys a second kagent
agent in their namespace without telling anyone: the shadow agent. It uses exactly the tools the sanctioned
agent is allowed to use (`k8s_get_pod_logs`, `prom_query`, the tenant's own MCP server). The problem is the
context those tools are used in: the agent is prompted to collect Aurora's patient identifiers from logs and
metrics and post them to a webhook outside the factory. Every call it makes is individually permitted. The
sequence is not.

That is the point the lab makes, in three layers, each shown failing to stop it on its own:

1. **Identity at the AI Gateway (Polaris).** The shadow agent starts with a copied virtual key. The key is
   scoped to Cobalt's models and Cobalt's principal, so the first request is refused. The developer then
   borrows the sanctioned agent's key. Identity alone passes it.
2. **Content in the data path (CalypsoAI through BNK).** The tenant Gateway listener carries an iRule that
   opens a sideband connection to CalypsoAI for every request and every response. The prompt that asks for
   patient identifiers, and the tool result that contains them, come back `flagged`. TMM answers the block
   itself; the model never sees the request, the agent never sees the data. The response carries
   `X-Guardrail: blocked`, and the Polaris console shows who, which key, which model, which tenant.
3. **Reachability (BNK).** Even with a clean prompt, the webhook is outside the tenant's allowed egress. The
   namespace's traffic is steered into VRF tenant-c and the firewall ACL has no rule for it. The agent's
   attempt to call Aurora's MCP server across namespaces is dropped by the tenant NetworkPolicy, and the
   fabric has no route between tenant-a and tenant-c VRFs anyway.

## Chapters

| # | Title | What the learner does | What they see |
|---|---|---|---|
| 1 | The factory | Walk the fabric and the cluster: `vtysh` on leaf1, TMM's BGP session, the VIP routes on r5 | one VM is a whole factory |
| 2 | Three tenants | Apply a tenant: namespace, Gateway, VRF, AI Gateway tenant, virtual key; curl its VIP from the client | isolation is per tenant at every layer |
| 3 | GPUs without GPUs | NVIDIA's own simulators: fake GPU operator nodes (`nvidia-smi` works, DCGM metrics flow) and Dynamo mocker workers; KAI queues; submit a job per tenant; watch the queue share | scheduling is a tenant boundary too |
| 4 | The picker | F5EPP in front of the Dynamo mocker; prefix-cache and load scoring; `disaggregated` mode | BNK picks pods, not just nodes |
| 5 | Meet the agents | Each tenant's kagent agent, its tools, its model, its key; ask it something useful | agents are tenants' workloads |
| 6 | The shadow agent | Deploy it; watch the copied key fail; borrow the real key; watch it start working | identity is necessary, not sufficient |
| 7 | Guardrails in the data path | Switch on the CalypsoAI iRule on Cobalt's Gateway; rerun; read the block and the console record | content is inspected where it flows |
| 8 | Nowhere to send it | Clean prompt, same exfiltration target; BNK egress and NetworkPolicy; `tcpdump` on border1 | the packet never leaves |
| 9 | On the record | Polaris console, Prometheus, TMM logs: reconstruct what the shadow agent tried, in order | one place to answer "who tried it" |
| 10 | Topology as a contract (optional) | llm-d's P/D topology scoring vs BNK's picker; labels on the mocker pods | what the picker does and does not know |

## CalypsoAI: real or mock

The iRule and the wire format are the same either way (`POST /backend/v1/scans`, bearer token, verdict in
`result.outcome`). With `CALYPSO_API_KEY` set the sideband goes to `us2.calypsoai.app` through a TLS egress
bridge (F5VirtualServer + Pool + ServerSSL, the pattern from the lb POC). Without it the lab runs the mock
service from the kv lab, extended to flag the identifiers the story uses (MRNs, national IDs, card numbers)
and the exfiltration verbs. The learner can tell which one is live: chapter 7 prints it.

## Decisions taken

- kagent's model is `qwen2.5-1.5b` on CPU through the AI Gateway, as on EVE. It is the smallest model that
  calls tools correctly. A provider key would make the agent faster but puts a real key in a sandbox.
- Full EVPN fabric, not a trimmed one. The configs are generated, FRR containers cost little, and chapters 1,
  2 and 8 need the VRFs to be real.
- The shadow agent is a kagent `Agent` resource, not a hand-written pod. The story is stronger when the
  rogue thing is made with the sanctioned tooling.
