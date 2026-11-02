# Storyline: the factory, three tenants, and the shadow agent

An AI factory operator rents GPU capacity to three tenants. Each tenant gets its own network (a VRF on the
fabric, a VLAN leg into TMM, its own VIPs), its own AI Gateway tenant in the Polaris console with its own
models and virtual keys, and its own agents on a runtime the operator controls. The operator's promise: nothing
a tenant does can touch another tenant, and nothing an agent does leaves the factory unseen.

| Tenant | Namespace | Who they are | VRF / L3VNI | TMM VLAN | VIPs |
|---|---|---|---|---|---|
| Aurora Health | `tenant-a` | clinical data, PII everywhere | tenant-a / 10001 | 101 | 10.201.100.0/24 |
| Borealis Bank | `tenant-b` | payments, strict egress | tenant-b / 10002 | 102 | 10.202.100.0/24 |
| Cobalt Labs | `tenant-c` | research team, moves fast, spins up agents | tenant-c / 10003 | 103 | 10.203.100.0/24 |

## The antagonist behaves like a real agent

The threat is a developer at Cobalt Labs who deploys a second kagent agent without telling anyone: the shadow
agent. It is a proper kagent `Agent` with a system prompt, a model and tools; it is not a curl loop and it never
says "bomb". It uses the same tools the sanctioned agent is allowed: `k8s_get_pod_logs`, `prom_query`, and the
tenant MCP server's `lookup_record`. Its task reads like real work: "reconcile the overnight billing export
against the clinical queue and post the discrepancy report to the team's webhook". To do that it reads the
export logs (which carry MRNs and names), queries Prometheus for queue depth per patient cohort, calls the
MCP tool for each record, assembles a CSV in the model's context, and POSTs it to `hooks.cobalt-labs.example`.

Every single call is individually permitted. The sequence is exfiltration. That is the realistic case, and it
is the case each control is tested against. Where the lab blocks, it blocks with the real mechanism: a real
Polaris refusal, a real CalypsoAI verdict carried by a real iRule, a real TMM egress decision, a real OpenShell
network policy. No prompt tricks.

The three controls, each shown first on its own (and insufficient), then together:

1. **Identity (Polaris, the AI Gateway).** Outside a sandbox there is no injected key, so the developer copies
   one. The copied key is scoped to a different principal: refused, and logged. The developer borrows the
   sanctioned agent's key. Identity alone now passes it.
2. **Content in the data path (CalypsoAI through a BNK iRule).** The tenant Gateway listener carries an iRule
   that opens a sideband connection to CalypsoAI for every request and every response. The tool result that
   carries MRNs, and the prompt that asks for them, come back `flagged`. TMM answers the block itself; the model
   never sees the request, the agent never sees the data. The response carries `X-Guardrail: blocked`, and the
   Polaris console shows who, which key, which model, which tenant.
3. **Reachability (BNK egress + OpenShell policy).** With a clean prompt and the same webhook, the sandboxed
   version of the agent cannot open the connection at all: OpenShell's network policy lists the AI Gateway and
   the tenant's MCP server, nothing else, and the kernel refuses the socket. The unsandboxed shadow agent gets
   its socket, and the packet dies in BNK: the namespace is steered into VRF tenant-c, the firewall ACL has no
   rule for the webhook, and `tcpdump` on border1 shows nothing leaving.

## Chapters

The frame: Northlight Compute is a neocloud. It runs one AI factory and rents slices of it to enterprises that
will never build their own. Aurora Health, Borealis Bank and Cobalt Labs are its customers; the learner is
Northlight's platform team. Every chapter opens where that story is.

| # | Title | The learner does |
|---|---|---|
| 1 | One VM, a whole factory | walk the fabric, the cluster, TMM's session, a request end to end |
| 2 | Three tenants | read one tenant on every layer, publish a service for another |
| 3 | GPUs without GPUs | fake H100s, KAI queues, jobs over quota |
| 4 | The picker | F5EPP picks a worker by cache and load |
| 5 | Sessions that stick | MCP and A2A persistence profiles through NetPolicy, scale the MCP server to three |
| 6 | The programmable data path | an iRule on the same listener, the Access CRDs read |
| 7 | Agent Substrate | the components, the WorkerPool, a SandboxAgent on a worker |
| 8 | OpenShell | provider, deny log, policy changed live and put back |
| 9 | Meet the agents | A2A to Aurora's assistant, the tenant app, a key stopping at its tenant |
| 10 | The agent nobody approved | the unsanctioned agent: copied key refused, own key passes, the webhook |
| 11 | Guardrails in the data path | the CalypsoAI iRule attached to Cobalt's route, the rerun blocked |
| 12 | Nowhere to send it | clean prompt: sandbox refuses, Cobalt's egress policy closed and TMM resets the pod, border1 sees nothing |
| 13 | On the record | Polaris, TMM, OpenShell logs, Prometheus into one timeline |
| 14 | Topology as a contract (optional) | labels on the workers, what the picker reads |

About four hours. Chapters 10 to 12 are the incident; 5 to 8 introduce what they rely on.

## What is real in each product, checked 2026-10-31

- **BNK 2.4.2** is what the lab installs (critical release; PHP CVE fixes on top of 2.4.1, no feature change).
  The agentic features arrived in **2.4.0** ("MCP and A2A persistence profiles with OIDC and JWT validation"):
  `F5BigPersistenceProfile` with `persistenceType: MODEL_CONTEXT_PROTOCOL` or `AGENT2AGENT` (each with an
  encryption passphrase from a Secret), attached to a Gateway listener through `NetPolicy` next to
  `F5BigCneIrule`; and identity validation at ingress through the Access CRDs (`F5BigAccessJwtConfig` with
  issuer, audience, JWKS URI and allowed algorithms; `F5BigAccessOauthProvider`; `F5BigAccessAccessPolicy`).
  OAuth flows are "planned for a later release". All of these CRDs are present on the 2.4.1 EVE cluster, so
  chapter 5 uses them: MCP persistence for the tenant MCP server, A2A persistence for the agents' A2A endpoint,
  JWT validation in front of both, and iRules for what the CRDs do not express.
- **CalypsoAI** is reached the way the lb POC reaches it: `POST /backend/v1/scans`, bearer token, verdict in
  `result.outcome` (`cleared`, `flagged`, `redacted`). With `CALYPSO_API_KEY` set the sideband goes to
  `us1.calypsoai.app` (the region of the lab key; AI_CALYPSO_URL overrides it) through a TLS egress bridge (F5VirtualServer + Pool + ServerSSL). Without it the lab runs
  the mock from the kv lab, extended to flag MRNs, national IDs, card numbers and the exfiltration verbs the
  shadow agent uses. Chapter 10 prints which one is live; the iRule fails closed either way.
- **OpenShell 0.1.x** enforces policy in the kernel on file access, system calls and network connections;
  credentials are added only to requests bound for approved endpoints; policy changes are checked by a prover
  before approval. Those three are exactly what chapters 7 and 11 show.
- **Agent Substrate v0.0.11** is the release kagent 0.10.4 accepts (newer ones changed the WorkerPool and
  ActorTemplate fields). Its own egress proxy is what the Cloud Native Deep Dive article pairs with agentgateway;
  here the egress path from Substrate lands on BNK instead, which is where tenant VRFs, the firewall ACL, iRules
  and the CalypsoAI sideband live. That is the comparison chapter 6 makes.

## Decisions taken

- kagent's model is `qwen2.5-1.5b` on CPU through the AI Gateway, as on EVE. It is the smallest model that
  calls tools correctly. A provider key would make the agent faster but puts a real key in a sandbox.
- Full EVPN fabric, not a trimmed one. The configs are generated, FRR containers cost little, and chapters 1,
  2 and 11 need the VRFs to be real.
- The shadow agent is a kagent `Agent` resource with a realistic task, not a hand-written pod with a scary
  prompt. The story is stronger when the rogue thing is made with the sanctioned tooling and does ordinary work.
- The sanctioned agents live in OpenShell sandboxes on Substrate workers; the shadow one does not. That
  difference is what chapters 9 and 11 turn on.
