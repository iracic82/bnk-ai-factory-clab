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
| The internet | `fabric/nodes/r5/setup.sh` | r5 installs iptables at deploy and masquerades on its management interface, so a tenant's SNAT address never leaves the VM and the reply finds its way back through the fabric |
| NetworkPolicies | both manifests | The proxy accepts port 4000 from `f5-bnk` and TMM's internal self IP only (tenant-isolation admits nothing else from outside the namespace). The router accepts 50051 and 8080 from `f5-bnk` and that self IP only |

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

## Verified and still to verify

Verified on 2026-11-03 before the first play: the LiteLLM image `v1.106.6` and the extproc `v0.4.0` exist on
ghcr.io at the pinned digests; the firewall rule fields (`destination.ports`, `ipProtocol: tcp`, `action: reject`)
are in the 2.4.2 `f5-cnf-crds-n6lan` chart; Instruqt's `aws_accounts` keys and the variable names come from the
Instruqt docs; `model: "auto"` with the router on profile `lab-ai` is how the EVE lab ran it; the Nova inference
profile ids are the ones the earlier track used against Bedrock on 2026-09-12.

To verify on the first play: that the f5 team's pool hands out the account (the push of `config.yml` says so),
that LiteLLM's log carries the model name the check greps for, that Polaris admits `auto` through the hook before
the key's model scope is checked, that the router's two replicas each finish their download, and that r5's NAT
gives the proxy a reply. The chapter's commands print each of these.
