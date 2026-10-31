# Reference copies

Verbatim copies of the manifests and scripts this lab adapts, kept so the repository stands alone. Nothing in
here is applied as is; `install/*.sh` carries the adapted versions.

| Path | From | Used for |
|---|---|---|
| `home_k8s/ai2` | Home_k8s `install/ai2` | AI Gateway enable, GAIE CRDs, F5EPP + Dynamo mocker (`models/`), pool VIP |
| `home_k8s/ai3` | Home_k8s `install/ai3` | AI Gateway tenant, providers, models, keys (`20-aigw-setup.sh`) |
| `home_k8s/ai4` | Home_k8s `install/ai4` | kagent values, OpenShell, Agent Substrate, tenant egress |
| `home_k8s/gpu` | Home_k8s `install/gpu` | fake GPU operator, KAI scheduler, tenant queues |
| `home_k8s/fabric/bnk`, `home_k8s/legacy` | Home_k8s `install/fabric/bnk`, `install/legacy` | GlobalRoutingConfig, routing templates, Vrf/Vxlan/RoutingConfig, F5SPKVlan, egress |
| `home_k8s/agents`, `home_k8s/tenant-agent` | Home_k8s `agents`, `apps/tenant-agent` | the lab agent and the per-tenant agent |
| `kv-lab` | bnk-ai-kv-lab `instruqt/bnk-ai-demos-kv/manifests` | mock Calypso service and the guardrail iRule |

## Changes to make while adapting (from the security review of these copies, 2026-10-31)

- `ai4/40-agents-gateway.yaml`: the A2A HTTPRoute matches `/api/a2a/` as a prefix with no authentication. Here
  it becomes an exact path per published agent, behind a virtual key on the tenant Gateway, and tenant
  namespace agents are not reachable from the shared VIP at all.
- `agents/bnk-lab-agent.yaml`: pod logs, resource YAML and connectivity tools stay only on agents that are not
  reachable from outside; the tool server's RBAC is scoped to the agent's own namespace.
- `tenant-agent/base/k8s/networkpolicy.yaml`: the kagent rule narrows from the whole namespace to the
  controller pod, on port 8001.
- `ai3/40-netpol.yaml`: the `default` namespace rule narrows to the TMM self IPs and the AI Gateway pods, on
  the ports they use.
