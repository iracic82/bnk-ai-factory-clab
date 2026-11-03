# The factory on one VM, as designed: containerlab fabric, r5 and client, the kind cluster with TMM on the fabric, the
# AI layer, the agents and their runtime, the guardrail path, and where each chapter looks. Writes docs/img/factory.svg.
# Static (no cluster to read yet); switch the data section to kubectl once the first Instruqt run exists.
# Re-run: python3 docs/img/factory.py
import os
W, H = 2400, 1380
o = []


def esc(t): return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, t, size=13, color="#334155", weight=400, anchor="start", mono=False):
    f = ' font-family="Consolas, Menlo, monospace"' if mono else ""
    o.append(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}"{f}>{esc(t)}</text>')


def box(x, y, w, h, fill="#ffffff", stroke="#94a3b8", r=10, sw=2, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')


def line(x1, y1, x2, y2, color="#64748b", sw=2, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    o.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{sw}"{d}/>')


def chapter(x, y, n):
    box(x - 14, y - 14, 28, 28, "#0f172a", "#0f172a", 14, 1)
    text(x, y + 5, str(n), 13, "#ffffff", 700, "middle")


o.append(f'<rect width="{W}" height="{H}" fill="#ffffff"/>')
text(W / 2, 40, "AI factory on one VM: containerlab fabric, kind, BNK 2.4.2, Polaris, NVIDIA simulators, agents, CalypsoAI", 26, "#0f172a", 700, "middle")
text(W / 2, 66, "Instruqt VM n2-standard-32, image f5/aibnk · numbered circles = the chapter that looks there (docs/storyline.md)", 14, "#475569", 400, "middle")

# ---- the VM frame
box(30, 90, W - 60, H - 150, "#fafafa", "#0f172a", 16, 2.5)
text(50, 116, "VM: docker, containerlab 0.75, kind v1.35.5, registry mirrors (/var/lib/bnk-mirrors), ollama (qwen2.5:1.5b on CPU)", 13.5, "#0f172a", 600)

# ---- fabric (left)
fx, fy = 50, 140
box(fx, fy, 700, 560, "#f0fdf4", "#16a34a", 12, 2)
text(fx + 16, fy + 26, "FRR EVPN fabric (quay.io/frrouting/frr:10.6.2), configs from fabric/gen.py", 15, "#15803d", 700)
chapter(fx + 680, fy + 22, 1)
nodes = {"client": (fx + 90, fy + 80), "r5": (fx + 90, fy + 170), "border1": (fx + 90, fy + 290),
         "spine1": (fx + 300, fy + 170), "spine2": (fx + 300, fy + 400), "leaf1": (fx + 540, fy + 230), "leaf2": (fx + 540, fy + 420)}
asn = {"client": "172.16.250.10", "r5": "AS 65500", "border1": "AS 65209 · VRF-lite to r5", "spine1": "AS 65200", "spine2": "AS 65200",
       "leaf1": "AS 65201 · VTEP, TMM's gateway", "leaf2": "AS 65202 · VTEP"}
for a, b in [("client", "r5"), ("r5", "border1"), ("border1", "spine1"), ("border1", "spine2"), ("spine1", "leaf1"), ("spine1", "leaf2"), ("spine2", "leaf1"), ("spine2", "leaf2")]:
    line(*nodes[a], *nodes[b], "#16a34a", 2)
for n, (x, y) in nodes.items():
    box(x - 60, y - 22, 120, 44, "#ffffff", "#16a34a", 8, 2)
    text(x, y - 2, n, 14, "#14532d", 700, "middle"); text(x, y + 14, asn[n], 10.5, "#166534", 400, "middle")
text(fx + 16, fy + 500, "VRFs on leaves and border1: external (L3VNI 10000), tenant-a/b/c (10001-10003), RT 65000:<vni>", 12.5, "#166534")
text(fx + 16, fy + 522, "leaf1 eth3 -> bnk-worker eth1: untagged 172.16.10.0/24 (TMM .11, leaf .1 as AS 65000) + VLAN 101-103 (172.17.10x.0/24)", 12.5, "#166534")
text(fx + 16, fy + 544, "r5 gives every VRF a default and takes the VIP pools and tenant SNAT pools back; the client stands in for the internet, and r5 masquerades to the real one (chapter 15)", 12.5, "#166534")

# ---- kind cluster (right)
kx, ky, kw = 780, 140, W - 830
box(kx, ky, kw, 1170, "#eff6ff", "#2563eb", 12, 2)
text(kx + 16, ky + 26, "kind cluster bnk (Calico, feature gates for Substrate): bnk-control-plane · bnk-worker (app=f5-tmm) · bnk-worker2 (workload=ai, fake H100s)", 15, "#1d4ed8", 700)

# BNK row
bx, by = kx + 16, ky + 46
box(bx, by, kw - 32, 200, "#ffffff", "#dc2626", 10, 2)
text(bx + 14, by + 24, "BNK 2.4.2 host mode (f5-bnk): TMM on bnk-worker, 2 Gi hugepages · OcNOS BGP AS 65100 to leaf1 · legacy network model (Vrf, RoutingConfig) · F5BnkGateway VIP pool 172.16.100.10-29", 13.5, "#b91c1c", 700)
chapter(bx + kw - 60, by + 20, 2); chapter(bx + kw - 95, by + 20, 5)
cols = [("external leg 1.1", "172.16.10.11/24 · VIPs 172.16.100.x · BGP to leaf1"),
        ("tenant legs", "VLAN 101/102/103 · 172.17.10x.11 · eBGP in each VRF · VIP 10.20x.100.10 · SNAT 10.20x.200.10"),
        ("internal leg 1.2", "<kind net>.0.250 · node -> TMM egress tunnels (F5SPKEgress per tenant)"),
        ("per request", "F5BigCneIrule + NetPolicy · F5BigPersistenceProfile MODEL_CONTEXT_PROTOCOL / AGENT2AGENT · Access JWT CRDs")]
cw = (kw - 60) / 4
for i, (h, d) in enumerate(cols):
    x = bx + 14 + i * cw
    box(x, by + 40, cw - 12, 140, "#fef2f2", "#fca5a5", 8, 1.5)
    text(x + 10, by + 64, h, 13.5, "#991b1b", 700)
    words, lines_, cur = d.split(" "), [], ""
    for wd in words:
        if len(cur) + len(wd) > 34: lines_.append(cur); cur = wd
        else: cur = (cur + " " + wd).strip()
    lines_.append(cur)
    for j, l in enumerate(lines_[:5]): text(x + 10, by + 86 + j * 18, l, 11.5, "#7f1d1d")

# AI row
ax, ay = kx + 16, by + 216
box(ax, ay, kw - 32, 250, "#ffffff", "#7c3aed", 10, 2)
text(ax + 14, ay + 24, "AI layer", 14, "#6d28d9", 700)
chapter(ax + kw - 60, ay + 20, 3); chapter(ax + kw - 95, ay + 20, 4); chapter(ax + kw - 130, ay + 20, 15)
cells = [("Polaris AI Gateway", "console :3000 · tenants lab, tenant-a/b/c · providers dynamo + ollama + bedrock · virtual keys · routes 172.16.100.13 / .20 / .21 / .22"),
         ("NVIDIA Dynamo 1.5.1", "aigw-models: Frontend + 2 Mocker decode workers (vllm:* metrics, KV events on NATS) · simulated, no GPU"),
         ("F5 Endpoint Picker", "F5EPP engine dynamo · prefix-cache + prefill-load scorers · InferencePool model-pool behind VIP 172.16.100.12:8000"),
         ("Cloud tier + router", "semantic-router x2 (f5-bnk): ext_proc on profile lab-ai, model auto · bedrock-proxy x2 (tenant-a) -> Nova micro/lite/pro on Bedrock · exit: egress-allow-a rule cloud-tier tcp/443"),
         ("GPU simulators", "fake GPU operator 0.2.1: 4 x H100 per worker, nvidia-smi + DCGM · KAI v0.18.6 queues ai-factory -> tenant-a/b/c (4/2/2)"),
         ("Observability", "kube-prometheus-stack · Grafana :30300 · Prometheus :30909 · scrapes mocker, picker, DCGM")]
cw = (kw - 60) / 6
for i, (h, d) in enumerate(cells):
    x = ax + 14 + i * cw
    box(x, ay + 40, cw - 12, 190, "#f5f3ff", "#c4b5fd", 8, 1.5)
    text(x + 10, ay + 64, h, 13.5, "#5b21b6", 700)
    words, lines_, cur = d.split(" "), [], ""
    for wd in words:
        if len(cur) + len(wd) > 30: lines_.append(cur); cur = wd
        else: cur = (cur + " " + wd).strip()
    lines_.append(cur)
    for j, l in enumerate(lines_[:7]): text(x + 10, ay + 86 + j * 18, l, 11.5, "#4c1d95")

# agents row
gx, gy = kx + 16, ay + 266
box(gx, gy, kw - 32, 330, "#ffffff", "#0891b2", 10, 2)
text(gx + 14, gy + 24, "Agents and their runtime", 14, "#0e7490", 700)
for i, n in enumerate([6, 7, 8, 9]): chapter(gx + kw - 60 - i * 35, gy + 20, n)
tenants = [("tenant-a · Aurora Health", "clinical queue, MRNs", "#0b6bcb"), ("tenant-b · Borealis Bank", "payments under review", "#a3367a"), ("tenant-c · Cobalt Labs", "experiments + the shadow agent", "#b35c00")]
tw = (kw - 60) / 3
for i, (n, w, c) in enumerate(tenants):
    x = gx + 14 + i * tw
    box(x, gy + 40, tw - 12, 180, "#ecfeff", c, 8, 1.5)
    text(x + 10, gy + 64, n, 13.5, c, 700)
    text(x + 10, gy + 86, f"MCP server: {w}", 11.5, "#155e75")
    text(x + 10, gy + 106, "kagent Agent assistant · own AI Gateway key", 11.5, "#155e75")
    text(x + 10, gy + 126, "OpenShell sandbox: key injected only toward 172.16.100.2x", 11.5, "#155e75")
    text(x + 10, gy + 146, "Substrate SandboxAgent on WorkerPool kagent-default", 11.5, "#155e75")
    text(x + 10, gy + 166, "published VIP 172.16.100.16-18 · NetworkPolicy tenant-isolation", 11.5, "#155e75")
    if i == 2:
        box(x + 10, gy + 182, tw - 32, 30, "#fff7ed", "#ea580c", 6, 1.5, "5,4")
        text(x + 18, gy + 202, "billing-reconciler (chapter 9): billing_export -> lookup_record (Aurora) -> post_report(webhook)", 11, "#9a3412", 700)
text(gx + 14, gy + 250, "kagent 0.10.4 (UI :30808, k8s tool server read-only) · operator agent factory-operator · NVIDIA OpenShell 0.1.5 gateway + Agent Sandbox v1.0.7 · Agent Substrate v0.0.11", 12.5, "#155e75")
text(gx + 14, gy + 272, "model for every agent: qwen2.5-1.5b on ollama (CPU, on the VM), reached only through the Polaris AI Gateway", 12.5, "#155e75")
text(gx + 14, gy + 294, "controls in order: Polaris identity (virtual key per principal) -> CalypsoAI content scan in TMM -> OpenShell network policy -> BNK egress in the tenant VRF", 12.5, "#155e75", 600)

# guardrails row
hx, hy = kx + 16, gy + 346
box(hx, hy, kw - 32, 170, "#ffffff", "#ca8a04", 10, 2)
text(hx + 14, hy + 24, "Guardrails in the data path (guardrails namespace)", 14, "#a16207", 700)
for i, n in enumerate([10, 11, 12]): chapter(hx + kw - 60 - i * 35, hy + 20, n)
text(hx + 14, hy + 52, "request -> TMM (tenant-c-ai listener) -> iRule: Content-Length checks, collect body -> sideband POST /backend/v1/scans -> verdict -> block (X-Guardrail: blocked, model never sees it) or release", 12.5, "#713f12")
text(hx + 14, hy + 76, "scanner = mock-calypso (always; MRN / ID / card shapes, exfiltration verbs) or calypso-bridge -> real CalypsoAI project AI-Instruqt (token in the bridge, never in the iRule)", 12.5, "#713f12")
text(hx + 14, hy + 100, "attached by the learner: NetPolicy guardrails-tenant-c (extensionRefs F5BigCneIrule guardrails, targetRefs Gateway tenant-c-ai)", 12.5, "#713f12")
text(hx + 14, hy + 124, "where the webhook dies: OpenShell refuses the socket inside a sandbox; outside one, the packet enters VRF tenant-c and the firewall ACL has no rule for it; tcpdump on border1 shows nothing", 12.5, "#713f12")
text(hx + 14, hy + 148, "on the record: Polaris console (who, key, model, tenant), Prometheus, TMM log, OpenShell audit", 12.5, "#713f12")

# link fabric -> cluster
line(fx + 600, fy + 230, kx, by + 100, "#dc2626", 3)
text(fx + 610, fy + 215, "veth leaf1 eth3 = bnk-worker eth1", 11, "#b91c1c", 700)
line(fx + 600, fy + 420, kx, ay + 120, "#2563eb", 2, "6,4")
text(fx + 610, fy + 445, "leaf2 eth3 = bnk-worker2 eth1 (spare)", 11, "#1d4ed8")

text(W / 2, H - 22, "docs/storyline.md for the chapters · install/*.sh in order 00, 05, 10, 20, 30, 35, 40, 45, 50, 60 · re-run this script to redraw", 13, "#475569", 400, "middle")
o.insert(0, f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="Segoe UI, Helvetica, Arial, sans-serif" font-size="12"><title>AI factory on one VM: fabric, kind, BNK, Polaris, simulators, agents, guardrails</title>')
o.append('</svg>')
open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'factory.svg'), 'w').write('\n'.join(o))
print(W, H)
