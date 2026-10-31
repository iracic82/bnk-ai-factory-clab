---
slug: openshell
id: fwycg1vescme
type: challenge
title: 8. OpenShell
teaser: The sanctioned assistants run in OpenShell sandboxes. A provider injects the
  tenant's key toward one host and nothing else; the sandbox's network policy refuses
  every other connection and logs it. Try to get out, then change the policy and try
  again.
notes:
- type: text
  contents: |-
    **Northlight Compute, week five.** Aurora's compliance review asks the question every platform team dreads: "If
    the assistant's code is wrong, or its prompt is wrong, what can it reach?" Northlight's answer has to be a list,
    not a promise.

    NVIDIA OpenShell is that list, enforced. A sandbox runs the agent's workload under gVisor with a supervisor
    beside it. A **provider** describes one external service and the credential for it; the supervisor adds the
    credential to requests bound for that endpoint, so the key is never inside the sandbox. The **network policy**
    is an allow-list by binary and destination; everything else is denied and written to the log.

    The three tenant sandboxes were created at track start. This chapter reads one, tests its edges, and changes
    the policy while it runs.
tabs:
- id: efrfngbgwu1c
  title: Terminal
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: aqluyieuocjq
  title: Terminal 2
  type: terminal
  hostname: factory
  cmd: /bin/bash -l
- id: hbourwi969qk
  title: Lab Topology
  type: service
  hostname: factory
  path: /topology#sandbox
  port: 5050
difficulty: intermediate
timelimit: 1800
enhanced_loading: false
---

# OpenShell

Every assistant in this factory holds a virtual key, and a key that an agent holds is a key an agent can be talked
into leaking. Borealis Bank's security review says exactly that, in writing, before they will let their assistant
near a customer. Mira's answer is where the sanctioned assistants already run: NVIDIA OpenShell sandboxes. The
sandbox never holds the key. A provider injects it on the way out, towards one address only, and anything else the
agent tries to reach is refused in the kernel and written to a log with the name of the binary that tried.

![The tenant-a sandbox with no key in its environment, the provider that injects Aurora's key towards one endpoint, the Aurora route answering 200 and the Borealis route DENIED, and the two policy commands that change the rules live](../assets/scene-08.png)

[button label="Open the Lab Topology" variant="outline"](tab-2)

The **Lab Topology** tab opens on **An agent in an OpenShell sandbox**: one green hop and one red one.

## The gateway and the three sandboxes

The OpenShell gateway runs in the cluster. The CLI on this VM talks to it over mTLS with the bundle the chart
generated, registered as gateway `factory`:

```bash,run
openshell status
openshell sandbox list
kubectl -n openshell get pods -o wide --no-headers | awk '{printf "%-40s %-10s %s\n", $1, $3, $7}'
```

Three sandboxes, one per tenant, all `Ready`. Each one is a pod under the gateway's control, but what matters is
what is inside and what it may reach. Aurora's sandbox has one provider: a profile whose only endpoint is Aurora's AI
Gateway route and whose credential is Aurora's virtual key:

```bash,run
sed -e '/^#/d' $LAB_ROOT/.cache/openshell-profile-tenant-a.yaml
openshell sandbox provider list tenant-a-agent
```

Read the profile twice. `endpoints` names the single host and port the credential may be sent to. `credentials` is
the environment variable the agent sees, and the header OpenShell writes it into on the way out. The value itself is
not in the file and not in the sandbox.

## What it can reach

From inside the sandbox, Aurora's route answers, and the request arrived with a key the sandbox never had. Borealis's
route, one address over, is refused before a packet leaves. And the environment inside has no key at all:

```bash,run
openshell sandbox exec --name tenant-a-agent -- sh -c 'curl -s -m 8 -o /dev/null -w "Aurora route 172.16.100.20: HTTP %{http_code}\n" http://172.16.100.20/v1/models'
openshell sandbox exec --name tenant-a-agent -- sh -c 'curl -s -m 8 -o /dev/null -w "Borealis route 172.16.100.21: HTTP %{http_code}\n" http://172.16.100.21/v1/models || echo "Borealis route: refused by the sandbox"'
openshell sandbox exec --name tenant-a-agent -- sh -c 'env | grep -i key || echo "no key in the sandbox environment"'
```

Keep **Terminal 2** on the sandbox's log for the rest of the chapter. Every refusal is a line with the binary, the
destination and the reason:

```
openshell logs tenant-a-agent --follow --source sandbox | grep -E 'DENIED|NET:OPEN'
```

And the same lines, from here:

```bash,run
openshell logs tenant-a-agent --since 5m --source sandbox | grep -E 'DENIED|NET:OPEN' | tail -5
```

The Borealis attempt is there, with `/usr/bin/curl` and `172.16.100.21:80`. This is what Borealis's reviewer asked
for: not a promise that the agent will behave, but a record of each time it did not.

## Where the key appears

Prove the injection from the other side. Polaris records every call under the key that made it. The sandbox's call
to Aurora's route landed under Aurora's app key, which the sandbox cannot print:

```bash,run
K=$(cat /root/.bnk/aigw/tenant-a.key); echo "Aurora's key ends in ...${K: -6}"; unset K
openshell sandbox exec --name tenant-a-agent -- sh -c 'curl -s -m 60 http://172.16.100.20/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"tenant-a-qwen2.5-1.5b\",\"messages\":[{\"role\":\"user\",\"content\":\"Say ok.\"}],\"max_tokens\":4}" | head -c 200'; echo
```

No `Authorization` header was written by the sandbox, and the model answered. The provider added it between the
sandbox and the wire.

## Change the policy while it runs

`policy get --base` prints the sandbox's base policy. `policy update` adds one network rule without touching the
rest and hot-reloads it. Add a rule for curl to reach Borealis's route:

```bash,run
openshell policy get tenant-a-agent --base | sed -n '1,40p'
openshell policy update tenant-a-agent --rule-name borealis --binary /usr/bin/curl --add-endpoint 172.16.100.21:80:read-write:rest:enforce --wait
openshell sandbox exec --name tenant-a-agent -- sh -c 'curl -s -m 8 -o /dev/null -w "Borealis route after the rule: HTTP %{http_code}\n" http://172.16.100.21/v1/models'
```

A `401` now. The packet got out, and Polaris refused it because no key was injected for that host: the provider knows
one endpoint, and this is not it. Two layers, two different answers, and Terminal 2 shows no `DENIED` for this one.

Put the base policy back. The script below removes the rule from a copy of the current policy and sets it as the
new base:

```bash,run
openshell policy get tenant-a-agent --base | sed -n '/^[a-z]/,$p' > /tmp/tenant-a-base.yaml
python3 - <<'EOF'
import yaml
p = yaml.safe_load(open('/tmp/tenant-a-base.yaml'))
net = p.get('network', {})
for key in ('rules', 'policies'):
    if isinstance(net.get(key), list):
        net[key] = [r for r in net[key] if r.get('name') != 'borealis']
open('/tmp/tenant-a-base.yaml', 'w').write(yaml.safe_dump(p, sort_keys=False))
EOF
openshell policy set tenant-a-agent --policy /tmp/tenant-a-base.yaml --wait
openshell sandbox exec --name tenant-a-agent -- sh -c 'curl -s -m 8 -o /dev/null -w "Borealis route: HTTP %{http_code}\n" http://172.16.100.21/v1/models || echo "Borealis route: refused again"'
openshell policy get tenant-a-agent --base | grep -c borealis | sed 's/^/rules named borealis left: /'
```

Refused again, logged again. Nothing restarted.

## What Mira sends to Borealis

- The key lives in the provider, not in the sandbox. A copied key cannot leave because it was never there.
- The allow-list is per binary and per destination, enforced in the sandbox's kernel, and every refusal is logged
  with the binary that tried.
- Policy changes are live. Chapter 12 relies on exactly this: a clean prompt and a webhook the policy does not list.

## Checkpoint

The check expects the OpenShell gateway connected, `tenant-a-agent` Ready, at least one `DENIED` line in its sandbox
log, and no rule named `borealis` left in its base policy.
