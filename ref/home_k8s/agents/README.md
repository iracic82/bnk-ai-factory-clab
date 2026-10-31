# kagent agents

Every `.yaml` file here is deployed by Argo CD application **`kagent-agents`** (auto sync). Merge a file to `main` and
the agent runs within about three minutes; delete the file and the agent is removed. Nothing to build: a kagent agent
is a declaration (prompt, model, tools) that the kagent controller turns into a running pod.

Project `kagent-agents` only allows `kagent.dev` objects (Agent, RemoteMCPServer, ModelConfig, ...) in namespace
`kagent`, so a file here cannot change BNK, RBAC or anything else.

## Add an agent

1. Copy `bnk-lab-agent.yaml` to `<name>.yaml` and change `metadata.name`, `description`, `systemMessage`, the tools
   and the A2A skills.
2. Open a pull request. CI (`.github/workflows/agentic-app.yml`) checks the file parses and only holds kagent.dev
   objects.
3. Merge. Argo creates the agent; check it in the kagent UI (https://kagent.10.10.12.35.nip.io) or with
   `kubectl -n kagent get agents`.

Minimal agent:

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: gpu-watch
  namespace: kagent
spec:
  description: Reports on the AI factory GPUs.
  type: Declarative
  declarative:
    runtime: go
    modelConfig: default-model-config          # qwen2.5-1.5b through the F5 AI Gateway
    systemMessage: |
      You watch the GPUs of a one-rack AI factory. Use the tools, answer briefly with numbers.
    tools:
    - type: McpServer
      mcpServer:
        name: ai-factory-mcp                    # our MCP server (apps/agentic-app)
        kind: RemoteMCPServer
        apiGroup: kagent.dev
        toolNames: [gpu_status, prom_query]
```

## What can an agent use

| Tools (RemoteMCPServer) | Tools | Notes |
|---|---|---|
| `kagent-tool-server` | `k8s_get_resources`, `k8s_describe_resource`, `k8s_get_events`, `k8s_get_pod_logs`, `k8s_get_resource_yaml`, `k8s_check_service_connectivity` (and more) | ships with kagent, runs `--read-only` |
| `ai-factory-mcp` | `gpu_status`, `lab_endpoints`, `prom_query` | ours, read-only, allowlisted PromQL |

Model: `default-model-config` (`qwen2.5-1.5b` via the F5 AI Gateway, virtual key `kagent-key`). A new model needs a
virtual key that allows it (`install/ai4/10-aigw-agent-model.sh`).

## Reaching an agent

- kagent UI: https://kagent.10.10.12.35.nip.io (login), every agent appears there.
- A2A: `http://10.10.12.34/api/a2a/kagent/<agent-name>/` through BNK Gateway `kagent/agents-gw`. The Gateway and
  route are BNK config, so they live in `install/ai4/40-agents-gateway.yaml` (Argo app `agents`, manual sync).

More: [docs/agents.md](../docs/agents.md).
