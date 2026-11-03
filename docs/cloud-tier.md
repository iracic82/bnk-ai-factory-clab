# The cloud tier and the model router (chapter 15)

Built 2026-11-03. Aurora Health rents a model Northlight does not run: Amazon Nova on Bedrock. Three pieces keep
the rental inside Northlight's rules, and this page is the current state of each, with the production shape next
to it.

```
                   model: auto                                               Amazon Bedrock, us-east-1
client ──▶ lab route 172.16.100.13 ──▶ Polaris (AI Gateway) ──┐                 nova-micro / nova-lite / nova-pro
                                        │                      │                          ▲
                                        │ ext_proc (gRPC 50051)│ provider lab-bedrock     │ https, SigV4
                                        ▼                      ▼                          │
                               semantic-router x2       bedrock-proxy x2 (tenant-a) ──veth──▶ vxlan100 ──▶ TMM egress (tenant-a)
                               (f5-bnk, 10 Gi each)     LiteLLM v1.106.6                  │ egress-allow-a
                               poem   -> qwen2.5-0.5b   ladder pro -> lite -> micro       ├─ cloud-tier tcp/443 accept, logged  ──▶ SNAT 10.201.200.10 ──▶ VLAN 101 ──▶ border1 ──▶ r5 ─MASQ─▶ internet
                               STEM   -> nova-lite                                        └─ allow-all
                               reason -> nova-pro
                               rest   -> qwen3-0.6b-dynamo ──▶ InferencePool model-pool ──▶ F5EPP picks the worker (chapter 4)
```

## What was added

| Piece | Where | What it is |
|---|---|---|
| Model router | `manifests/ai/70-semantic-router.yaml`, StatefulSet `semantic-router` in `f5-bnk`, 2 replicas | vLLM Semantic Router extproc v0.4.0, the same manifest the EVE lab ran, as the ext_proc of the lab tenant's AI Gateway profile `lab-ai`. A request with model `auto` is classified (keywords, an MMLU domain classifier, an embedding similarity for creative prompts) and the model is rewritten before Polaris picks a provider. Each replica downloads about 3.6 GB of models from Hugging Face on first start into its own volume |
| Attach | `install/lib/attach-router.sh` | Waits for a Ready router pod, then `PUT /api/v1/tenants/lab/profiles/lab-ai/semantic-router {"name":"semantic-router","port":50051,"timeoutMs":1000}` and waits for the profile to be Programmed. `install/40-ai.sh` starts it in the background at track start (`/var/log/setup-router-attach.log`); chapter 15 runs it by hand when needed |
| Cloud tier | `manifests/ai/60-bedrock-proxy.yaml`, Deployment `bedrock-proxy` in `tenant-a`, 2 replicas, a PodDisruptionBudget, anti-affinity across the workers | LiteLLM, pinned by digest, speaking Bedrock's Converse API for `us.amazon.nova-{micro,lite,pro}-v1:0` with two retries, a 60 s timeout and a fallback ladder. It demands its own key (Secret `bedrock-proxy`, generated at install) and signs with the AWS keys from Secret `bedrock-aws`. Polaris registers it as the Generic provider `<tenant>-bedrock` in every tenant, with models `nova-micro`, `nova-lite`, `nova-pro` |
| Credentials | `instruqt/bnk-ai-factory-clab/config.yml` (`aws_accounts`), `track_scripts/setup-factory`, `install/40-ai.sh` | An AWS account from the f5 team's pool with Bedrock and STS enabled in us-east-1 and `AmazonBedrockFullAccess`. Instruqt injects `INSTRUQT_AWS_ACCOUNT_BEDROCK_AWS_ACCESS_KEY_ID` and `_AWS_SECRET_ACCESS_KEY` into the lifecycle scripts; setup-factory writes them to one file, 40-ai.sh turns the file into the Secret and shreds it. No account, no cloud tier, and the lab runs as before |
| The exit rule | `manifests/bnk/30-egress.yaml`, `manifests/chapters/15-cloud-closed-a.yaml` | `egress-allow-a` has two rules in order: `cloud-tier` (tcp/443, accept, logged) and `allow-all`. Chapter 15 flips the first to reject and back, the way chapter 12 does for Cobalt |
| The internet | `fabric/nodes/r5/setup.sh`, `install/10-fabric.sh` | r5 masquerades on its management interface, so a tenant's SNAT address never leaves the VM and the reply finds its way back through the fabric. The FRR image has no iptables; setup.sh asks apk for it, and because the management network is not always up at first boot (first play, 2026-11-03), 10-fabric.sh repeats the install with retries after the deploy and adds the rule |
| NetworkPolicies | both manifests | The proxy accepts port 4000 from `f5-bnk` and TMM's internal self IP only (tenant-isolation admits nothing else from outside the namespace). The router accepts 50051 and 8080 from `f5-bnk` and that self IP only |

## What the LLM Gateway itself does here (verified on the running lab, 2026-11-03)

BNK 2.4.1 added the LLM Gateway as Early Access, in the TMM data path, and the 2.4.2 build (Polaris 14.91.12)
is what this lab runs. The release notes list its capabilities: multi-provider routing with failover, virtual
keys, budgets and rate limits, JWT and OIDC inbound auth, per-request telemetry with cost, and a prompt cache that
2.4.1 limits to OpenAI and Anthropic models. A profile's `capabilities` on the API are the live version of that
list. Chapter 15 uses four of them on top of the router hook.

| Feature | Object and field | What chapter 15 does with it |
|---|---|---|
| Model scope per key | virtual key `modelScope`, set by `install/40-ai.sh` | only the lab tenant and Aurora get the Nova models; Cobalt's key on `tenant-a-nova-lite` is refused with `403 model_not_allowed` |
| Pricing per deployment | `AIModel.spec.deployments[].pricing`, micro-USD per million tokens | Nova list prices on the Bedrock deployment, a nominal 1 on the local one, so the model reports `Priced=True` and every request is recorded with a cost |
| Budgets | `POST /governance/budgets` with `ownerKind` (org, team, principal, vk), `ownerId`, `resetPeriod` (hourly, daily, weekly, monthly), `maxTokens`, `maxUsdMicros`, `softUsdMicros`, `action: block`; listed at `governance/<kind>s/<id>/budgets`, no GET by id, unknown fields silently dropped, the owner is not checked for existence | the pilot key `lab-pilot-key` (scope: the Nova models) has 40 tokens an hour; the sixth nine-token ask is refused with `429 budget_exceeded`, counted for the whole hour on that key |
| Failover | `AIGatewayProfile.spec.failover` (`maxAttempts`, `on5xx`, `on429`, `cooldown`, `honorRetryAfter`) | `nova-lite` has a second deployment on the local 1.5b at weight 1 against 100. With the exit closed the proxy answers 500, the gateway retries on the local deployment and the client gets "Mars" under the name `nova-lite` |
| Model routing hook | `AIGatewayProfile.spec.modelRouting.semanticRouter` | the vLLM semantic router, attached by `install/lib/attach-router.sh` |

Both the pricing and the failover went in as patches on the objects, because the API answers 405 to updates on a
model or a profile and has no sub-resource for either. The objects are the source of truth: the API reflected the
patched failover at once as `capabilities.failover: true`, and the profile was Programmed again within a minute.

One rule from F5 engineering about the LLM Gateway, relayed on 2026-11-03: its authentication runs for every path
under a Gateway, so an unauthenticated route cannot share a Gateway with it. The lab complies by construction, the
tenant apps and MCP servers are published on their own VIPs (172.16.100.16 to .18) and the AI routes on .13 and
.20 to .22.

## Why it is shaped this way

- **A cloud model is a provider, not a pool member.** Nova has no worker, no KV events and no metrics. The picker
  learns its workers from pods in its own cluster, which the BNK team confirmed on 2026-11-03 for release 2.4.x, so
  prefix-aware selection across anything external is development, not configuration. Nothing of the cloud tier
  touches the InferencePool.
- **The proxy lives in Aurora's namespace.** A namespace gets exactly one F5SPKEgress, and the egress objects are
  never created or deleted on a running lab (`docs/egress.md`). Sharing Aurora's exit costs nothing in the story,
  because Aurora is the tenant that rents the model, and avoids a fourth tunnel on a subsystem that has bitten
  twice.
- **Nova needs the proxy.** Bedrock's OpenAI-compatible endpoint serves open-weight models only. The Nova Lite
  model card lists Chat Completions as not supported. Open-weight models such as gpt-oss could be reached from
  Polaris directly as a Generic provider with a Bedrock API key, but then the gateway pod itself would need an exit,
  and it has none.
- **A port rule, not a name.** The 2.4.2 CRD takes `destination.fqdns`, and `bedrock-runtime.us-east-1.amazonaws.com`
  is the honest allowlist entry. A name in a rule needs TMM's global FQDN resolver (an `F5BigDnsCache` of type
  net-resolver with a DNS server TMM can reach), which this lab does not set up. The port rule is what is verified.
- **The router is attached to the lab tenant only.** Its decisions name the lab tenant's models. A tenant route
  would need a router config of its own, with that tenant's prefixed model names.

## What a production cluster does differently

1. **Credentials.** No keys in a Secret. On EKS, Pod Identity. On a BNK cluster elsewhere, IAM OIDC federation
   against the cluster's service account issuer, or short-term Bedrock API keys refreshed by a sidecar.
2. **The rule by name.** `destination.fqdns` with the regional Bedrock endpoint, after the FQDN resolver is set up,
   and `logging: true` kept.
3. **No internet at all** where the cluster has a path into AWS: a PrivateLink endpoint for bedrock-runtime, and
   the allowlist becomes one private address.
4. **The router's models baked into an image** or on a shared volume, so nothing downloads at start, plus a
   deliberate fail-open or fail-closed choice through the profile's `timeoutMs`.
5. **External GPU servers join as nodes** of the same cluster so the picker sees them as pods. A selector-less
   Service with hand-written endpoints gives plain load balancing only. Across sites, each site keeps its own BNK
   and picker, and site selection happens above the pool.

## The router's cache, tried and left off

The vLLM semantic router carries a semantic response cache (`global.stores.response_cache` plus a `response_cache`
plugin on each decision that should use it). On the first play it was configured on both cloud decisions, the
store initialised, and four identical questions cost four Bedrock calls with no lookup or store logged in either
router pod. The LLM Gateway's hook carries the request to the router and takes the model name back. The response
never passes through the router, so there is nothing to store. The config keeps the store declared and off, with
the keys recorded for a later release that passes responses. The LLM Gateway's own prompt cache is limited to
OpenAI and Anthropic models in 2.4.1, so Generic providers such as the proxy get no cache at the gateway either.

## Verified and still to verify

Verified on the first play (2026-11-03, participant vjkeaj3ey31c). The AWS account was handed out and the proxy
was Ready at setup. Both router pods were Ready eight minutes after apply and the hook was Programmed at 19:45.
`model: auto` sent a patient record to `qwen2.5-1.5b`, a prompt injection to `qwen2.5-0.5b`, a poem to
`qwen2.5-0.5b`, a binary-search question to `nova-lite` and a one-word reply to the pool. A direct `nova-micro`
request answered from Bedrock once r5 had its masquerade rule. Cobalt's key on `tenant-a-nova-lite` got
`403 model_not_allowed` and Aurora's key an answer. With pricing and the second deployment patched on `nova-lite`
and failover on the profile, two prompts during a closed exit were answered by the local deployment under the
name `nova-lite` while the proxy logged 500, and Bedrock answered again after the reopen. LiteLLM's log carries
`LiteLLM completion() model= converse/us.amazon.nova-micro-v1:0; provider = bedrock`, which the check greps. What
failed on that play: r5's deploy-time `apk add iptables` (management network not ready), fixed by hand and then in
`install/10-fabric.sh`, the router at 6 Gi with four classifiers (OOM-killed, now 12 Gi), and the router's cache
(see above).

Verified on 2026-11-03 before the first play: the LiteLLM image `v1.106.6` and the extproc `v0.4.0` exist on
ghcr.io at the pinned digests; the firewall rule fields (`destination.ports`, `ipProtocol: tcp`, `action: reject`)
are in the 2.4.2 `f5-cnf-crds-n6lan` chart; Instruqt's `aws_accounts` keys and the variable names come from the
Instruqt docs; `model: "auto"` with the router on profile `lab-ai` is how the EVE lab ran it; the Nova inference
profile ids are the ones the earlier track used against Bedrock on 2026-09-12.

To verify on the first play: that the f5 team's pool hands out the account (the push of `config.yml` says so),
that LiteLLM's log carries the model name the check greps for, that Polaris admits `auto` through the hook before
the key's model scope is checked, that the router's two replicas each finish their download, and that r5's NAT
gives the proxy a reply. The chapter's commands print each of these.
