#!/usr/bin/env python3
# One SVG per chapter, same style everywhere: a few boxes, the path the chapter follows, the thing it proves.
# Re-run after editing: python3 instruqt/bnk-ai-factory-clab/assets/diagrams.py   (writes NN-*.svg next to it)
import os

HERE = os.path.dirname(os.path.abspath(__file__))
INK, MUTE, LINE = "#0f172a", "#475569", "#64748b"
PAL = {"bnk": ("#fee2e2", "#dc2626"), "fab": ("#e0f2fe", "#0284c7"), "ten": ("#dcfce7", "#16a34a"),
       "ai": ("#fef3c7", "#d97706"), "agent": ("#ede9fe", "#7c3aed"), "bad": ("#fde68a", "#b45309"),
       "plain": ("#ffffff", "#94a3b8"), "dark": ("#0f172a", "#0f172a"), "guard": ("#fce7f3", "#be185d")}


class D:
    def __init__(self, w, h, title, sub=""):
        self.w, self.h, self.o = w, h, []
        self.o.append(f'<rect width="{w}" height="{h}" fill="#ffffff"/>')
        self.text(24, 34, title, 20, INK, 700)
        if sub:
            self.text(24, 56, sub, 12.5, MUTE)

    @staticmethod
    def esc(t): return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    def text(self, x, y, t, size=12.5, color=INK, weight=400, anchor="start", mono=False):
        f = ' font-family="Consolas, Menlo, monospace"' if mono else ' font-family="Inter, Segoe UI, Helvetica, Arial, sans-serif"'
        self.o.append(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}"{f}>{self.esc(t)}</text>')

    def box(self, x, y, w, h, kind="plain", title="", lines=(), r=10, sw=2, dash=None, mono_lines=False):
        fill, stroke = PAL[kind]
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>')
        tc = "#ffffff" if kind == "dark" else INK
        if title:
            self.text(x + w / 2, y + 20, title, 13, tc, 700, "middle")
        for i, l in enumerate(lines):
            self.text(x + w / 2, y + 40 + i * 16, l, 11.5, "#e2e8f0" if kind == "dark" else MUTE, 400, "middle", mono_lines)

    def arrow(self, x1, y1, x2, y2, label="", color=LINE, dash=None, sw=2, above=True):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.o.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{sw}"{d} marker-end="url(#ah)"/>')
        if label:
            mx, my = (x1 + x2) / 2, (y1 + y2) / 2 + (-6 if above else 16)
            self.text(mx, my, label, 11, color, 600, "middle")

    def note(self, x, y, t, color=MUTE, size=11.5, anchor="start"):
        self.text(x, y, t, size, color, 400, anchor)

    def badge(self, x, y, t, kind="dark"):
        fill, stroke = PAL[kind]
        w = 10 + 7.2 * len(t)
        self.o.append(f'<rect x="{x}" y="{y - 13}" width="{w}" height="20" rx="10" fill="{fill}" stroke="{stroke}"/>')
        self.text(x + w / 2, y + 1, t, 11, "#ffffff" if kind == "dark" else INK, 700, "middle")

    def save(self, name):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}">'
                '<defs><marker id="ah" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto" markerUnits="strokeWidth">'
                '<path d="M0,0 L10,4 L0,8 z" fill="#64748b"/></marker></defs>')
        open(os.path.join(HERE, name), "w").write(head + "".join(self.o) + "</svg>\n")


def ch01():
    d = D(980, 330, "One VM, a whole factory", "containerlab wires an FRR EVPN fabric, an exit router, a client and a three node kind cluster together on one machine")
    d.box(30, 90, 120, 60, "plain", "client", ["172.16.250.10"], mono_lines=True)
    d.box(190, 90, 100, 60, "fab", "r5", ["AS 65500"])
    d.box(330, 90, 110, 60, "fab", "border1", ["VRF-lite to r5"])
    d.box(480, 70, 220, 100, "fab", "spine1 / spine2", ["eBGP unnumbered", "EVPN route reflector"])
    d.box(740, 90, 100, 60, "fab", "leaf1", ["L3VNI 10000-3"])
    d.box(740, 190, 220, 110, "bnk", "bnk-worker  ·  TMM", ["eth1 = leaf1 eth3 (untagged + VLAN 101-103)", "self IP 172.16.10.11, BGP AS 65100"], mono_lines=True)
    d.box(480, 190, 220, 110, "plain", "bnk-control-plane · bnk-worker2", ["kind v1.35.5, Calico, Multus", "Dynamo, picker, agents"])
    d.arrow(150, 120, 190, 120); d.arrow(290, 120, 330, 120); d.arrow(440, 120, 480, 120); d.arrow(700, 120, 740, 120)
    d.arrow(790, 150, 790, 190, "handoff", "#dc2626")
    d.arrow(700, 245, 740, 245, "", LINE, "4 3")
    d.note(30, 215, "A request from the client to a VIP crosses: r5 → border1 (VRF) → EVPN → leaf1 → TMM → pod.")
    d.note(30, 235, "This chapter reads each hop's table before anything changes.")
    d.save("01-the-factory.svg")


def ch02():
    d = D(980, 340, "Three tenants, three routing domains", "A tenant is declared on the fabric, on BNK and in Kubernetes; nothing in one domain can reach another")
    y = 80
    for i, (t, n, vlan, vip, snat, who) in enumerate([("tenant-a", "Aurora Health", 101, "10.201.100.10", "10.201.200.0/24", "clinical queue"),
                                                        ("tenant-b", "Borealis Bank", 102, "10.202.100.10", "10.202.200.0/24", "payments"),
                                                        ("tenant-c", "Cobalt Labs", 103, "10.203.100.10", "10.203.200.0/24", "research")]):
        yy = y + i * 80
        d.box(30, yy, 170, 62, "ten", n, [t, who])
        d.box(240, yy, 200, 62, "bnk", f"Vrf {t} on TMM", [f"VLAN {vlan} leg, VIP {vip}", f"SNAT {snat}"], mono_lines=True)
        d.box(480, yy, 200, 62, "fab", f"leaf1 VRF {t}", [f"eBGP to TMM over VLAN {vlan}", f"accepts VIP + SNAT only"])
        d.box(720, yy, 230, 62, "fab", f"border1 → r5 .{vlan}", ["type-5 → VRF-lite", "r5 hands back a default"])
        d.arrow(200, yy + 31, 240, yy + 31); d.arrow(440, yy + 31, 480, yy + 31); d.arrow(680, yy + 31, 720, yy + 31)
    d.note(30, 330, "Chapter task: publish a second service for Borealis in its VRF and watch the /32 travel to r5.")
    d.save("02-three-tenants.svg")


def ch03():
    d = D(980, 320, "GPUs without GPUs", "The fake GPU operator advertises H100s the kernel has never seen; KAI schedules them with one queue per tenant")
    d.box(30, 80, 200, 90, "ai", "fake GPU operator", ["4 x NVIDIA-H100-80GB-HBM3", "per worker, device plugin + DCGM"])
    d.box(270, 80, 200, 90, "ai", "KAI scheduler", ["queue tree, quotas,", "fair share, preemption"])
    d.box(510, 60, 440, 130, "plain", "queues", [])
    d.box(530, 95, 120, 60, "ten", "tenant-a", ["Aurora, 4 GPUs"]); d.box(670, 95, 120, 60, "ten", "tenant-b", ["Borealis, 2"]); d.box(810, 95, 120, 60, "ten", "tenant-c", ["Cobalt, 2"])
    d.arrow(230, 125, 270, 125); d.arrow(470, 125, 510, 125)
    d.note(30, 225, "A training Job asks for nvidia.com/gpu; the scheduler places it inside its tenant's quota and parks what does not fit.")
    d.note(30, 245, "Grafana and Prometheus show the simulated utilisation per node and per queue.")
    d.save("03-gpus-without-gpus.svg")


def ch04():
    d = D(980, 330, "The picker", "F5's Endpoint Picker chooses the model worker per request from the workers' own KV-cache events and load")
    d.box(30, 100, 110, 60, "plain", "client", ["via r5"])
    d.box(180, 90, 170, 80, "bnk", "TMM · pool VIP", ["172.16.100.12:8000", "Gateway + HTTPRoute"], mono_lines=True)
    d.box(390, 70, 200, 120, "bnk", "F5EPP (engine dynamo)", ["prefix-cache scorer", "prefill / queue / KV scorers", "NATS kv-events, vllm:* metrics"])
    d.box(640, 70, 140, 50, "ai", "mocker worker 1", ["Dynamo DGD"]); d.box(640, 140, 140, 50, "ai", "mocker worker 2", ["Dynamo DGD"])
    d.box(820, 70, 130, 120, "ai", "NATS", ["kv-events", "per endpoint"])
    d.arrow(140, 130, 180, 130); d.arrow(350, 130, 390, 130, "ext-proc"); d.arrow(590, 95, 640, 95, "pick"); d.arrow(590, 165, 640, 165, "", LINE, "4 3")
    d.arrow(780, 95, 820, 110, "", "#d97706", "3 3"); d.arrow(780, 165, 820, 150, "", "#d97706", "3 3")
    d.note(30, 240, "Send the same prompt twice: the second lands where the prefix cache is. Load one worker: new requests move to the other.")
    d.save("04-the-picker.svg")


def ch05():
    d = D(980, 360, "Sessions that stick", "MCP and A2A keep state on the replica that created it; BNK 2.4 understands both protocols and keeps follow-ups there")
    d.box(30, 100, 110, 60, "plain", "client", ["via r5"])
    d.box(180, 80, 210, 100, "bnk", "TMM · Gateway tenant-mcp", ["172.16.100.23  (Aurora)", "F5BigPersistenceProfile", "MODEL_CONTEXT_PROTOCOL"], mono_lines=True)
    for i in range(3):
        d.box(440 + i * 150, 95, 130, 70, "ten", f"agent pod {i + 1}", ["MCP server :8001", "tenant-a"])
    d.arrow(140, 130, 180, 130); d.arrow(390, 130, 440, 130, "Mcp-Session-Id → same pod", "#16a34a")
    d.box(180, 220, 210, 100, "bnk", "TMM · Gateway agents-gw", ["172.16.100.14  (kagent)", "F5BigPersistenceProfile", "AGENT2AGENT"], mono_lines=True)
    d.box(440, 235, 280, 70, "agent", "kagent-controller :8083", ["/api/a2a/tenant-a/assistant/", "task id → same backend"])
    d.arrow(140, 160, 180, 250); d.arrow(390, 270, 440, 270, "message/send", "#7c3aed")
    d.note(30, 345, "Scale the MCP server to three. Without the profile a session's follow-ups land anywhere; with it they stay where the session lives.")
    d.save("05-sessions-that-stick.svg")


def ch06():
    d = D(980, 330, "The programmable data path", "Where the CRDs stop, an iRule continues: attached to a Gateway listener through a NetPolicy, running inside TMM")
    d.box(30, 100, 110, 60, "plain", "client", ["via r5"])
    d.box(180, 70, 260, 120, "bnk", "TMM · Gateway tenant-gw (Borealis)", ["172.16.100.17:80", "NetPolicy → F5BigCneIrule", "when HTTP_REQUEST { ... }"], mono_lines=True)
    d.box(490, 85, 170, 90, "ten", "agent-web (tenant-b)", ["the tenant's app", "unchanged"])
    d.box(710, 70, 240, 120, "guard", "Access CRDs (2.4.x)", ["F5BigAccessJwtConfig", "F5BigAccessOauthServer, ...", "JWT / OIDC at ingress"], mono_lines=True)
    d.arrow(140, 130, 180, 130); d.arrow(440, 130, 490, 130, "stamped")
    d.arrow(180, 160, 140, 180, "/factory/whoami answered by TMM", "#dc2626", above=False)
    d.note(30, 240, "One policy object, two kinds of extension: an iRule here, a persistence profile in chapter 5, the guardrail sideband in chapter 11.")
    d.note(30, 260, "The Access CRDs are read, not attached: an identity provider is outside this VM.")
    d.save("06-programmable-data-path.svg")


def ch07():
    d = D(980, 350, "Agent Substrate", "A scheduler and an egress path of their own for agents: WorkerPool, ActorTemplate, SandboxAgent")
    d.box(30, 80, 200, 90, "agent", "kagent controller", ["SandboxAgent →", "ActorTemplate (generated)"])
    d.box(280, 60, 300, 130, "agent", "ate-system", ["ate-api-server · ate-controller", "atelet on every node", "atenet-router (agentgateway) · atenet-dns", "pod certificates, mTLS everywhere"])
    d.box(630, 70, 320, 110, "ten", "WorkerPool kagent-default", ["2 workers, sandboxClass gvisor", "one golden snapshot per template", "actors forked from it in milliseconds"])
    d.arrow(230, 125, 280, 125); d.arrow(580, 125, 630, 125, "schedules actors")
    d.box(280, 230, 300, 70, "bnk", "the model call", ["actor → atenet-router → AI Gateway route", "the only way out"])
    d.arrow(790, 180, 430, 230, "", "#7c3aed")
    d.note(30, 330, "Compare: a plain pod gets scheduled, started and torn down by kubelet. An actor is forked from a warm snapshot on a worker.")
    d.save("07-agent-substrate.svg")


def ch08():
    d = D(980, 340, "OpenShell", "The runtime enforces what the agent may touch: a provider injects the key toward one host, the network policy refuses every other")
    d.box(30, 80, 300, 130, "agent", "sandbox tenant-a-agent", ["supervisor + workload (gVisor)", "provider f5-aigw-tenant-a", "key never inside the sandbox"])
    d.box(400, 70, 220, 70, "bnk", "172.16.100.20 (Aurora's route)", ["allowed · key injected"], mono_lines=True)
    d.box(400, 160, 220, 70, "bnk", "172.16.100.21 (Borealis)", ["DENIED by policy"], mono_lines=True)
    d.box(690, 70, 260, 160, "dark", "openshell CLI", ["policy get / policy update", "logs --source sandbox", "NET:OPEN [MED] DENIED ...", "every refusal is a log line"], mono_lines=True)
    d.arrow(330, 110, 400, 105, "", "#16a34a"); d.arrow(330, 170, 400, 195, "", "#b45309", "4 3")
    d.note(30, 260, "Add a host to the policy and the same call succeeds; put the base policy back and it is refused again. No pod restart in between.")
    d.save("08-openshell.svg")


def ch09():
    d = D(980, 350, "Meet the agents", "Each tenant has an assistant with its own model, its own key and its own tools; the operator's agent sees the platform, nothing of the tenants")
    for i, (t, n, vip) in enumerate([("tenant-a", "Aurora assistant", ".20"), ("tenant-b", "Borealis assistant", ".21"), ("tenant-c", "Cobalt assistant", ".22")]):
        d.box(30 + i * 230, 80, 200, 90, "ten", n, [f"kagent Agent in {t}", f"model {t}-qwen2.5-1.5b", f"route 172.16.100{vip}"], mono_lines=True)
    d.box(720, 80, 230, 90, "agent", "factory-operator", ["kagent namespace", "read-only Kubernetes tools", "lab tenant, route .13"])
    d.box(30, 220, 440, 70, "agent", "tenant MCP server (agent:8001)", ["lookup_record · tenant_identity · egress_check · reach_test"], mono_lines=True)
    d.box(510, 220, 440, 70, "bnk", "Polaris AI Gateway", ["one tenant per team, one virtual key per principal, every call recorded"])
    d.arrow(130, 170, 130, 220, "tools", "#7c3aed"); d.arrow(610, 170, 610, 220, "model", "#dc2626")
    d.note(30, 320, "Ask Aurora's assistant about its queue and watch the call appear in Polaris; the same key on Borealis's route is refused.")
    d.save("09-meet-the-agents.svg")


def ch10():
    d = D(980, 360, "The agent nobody approved", "A Cobalt developer deploys an agent with the sanctioned tooling; the task reads like night-shift work and the sequence is the problem")
    d.box(30, 80, 250, 120, "bad", "billing-reconciler (tenant-c)", ["kagent Agent, plain pod", "no sandbox, no WorkerPool", "Secret shadow-key: a copied key"])
    d.box(340, 70, 200, 60, "ten", "billing_export", ["Cobalt's own tool"])
    d.box(340, 140, 200, 60, "ten", "lookup_record", ["Aurora's MCP server"])
    d.box(600, 70, 180, 60, "bnk", "172.16.100.22", ["Cobalt's AI route"], mono_lines=True)
    d.box(600, 140, 180, 60, "plain", "post_report", ["a webhook outside"])
    d.box(820, 90, 130, 90, "plain", "client", ["172.16.250.10:8080", "the webhook"], mono_lines=True)
    d.arrow(280, 110, 340, 100, "1", "#7c3aed"); d.arrow(280, 150, 340, 170, "2", "#7c3aed"); d.arrow(280, 130, 600, 100, "model", "#dc2626", "4 3")
    d.arrow(540, 170, 600, 170, "3", "#7c3aed"); d.arrow(780, 170, 820, 150, "4", "#b45309")
    d.note(30, 240, "Polaris refuses the copied key (keys belong to a tenant). With Cobalt's own key the agent runs, and the report reaches the webhook.")
    d.note(30, 260, "Identity was necessary. It was not sufficient.")
    d.save("10-the-shadow-agent.svg")


def ch11():
    d = D(980, 340, "Guardrails in the data path", "A CalypsoAI verdict carried inline by a BNK iRule: the request is scanned where it flows, before the model sees it")
    d.box(30, 100, 180, 70, "bad", "billing-reconciler", ["same task again"])
    d.box(260, 70, 260, 130, "bnk", "TMM · Gateway tenant-c-ai", ["NetPolicy guardrails-tenant-c", "iRule: collect body, sideband scan,", "flagged → HTTP 200 + X-Guardrail: blocked"], mono_lines=True)
    d.box(570, 70, 180, 60, "guard", "CalypsoAI", ["/backend/v1/scans", "mock or the real service"])
    d.box(570, 140, 180, 60, "ai", "the model", ["never reached"])
    d.arrow(210, 135, 260, 135); d.arrow(520, 100, 570, 100, "sideband", "#be185d"); d.arrow(520, 170, 570, 170, "", LINE, "4 3")
    d.box(800, 70, 150, 130, "dark", "the record", ["Polaris: the call", "TMM: the verdict", "the agent: blocked"])
    d.note(30, 240, "Attach the policy to Cobalt's gateway with one kubectl apply. Rerun. The export never leaves the data plane.")
    d.save("11-guardrails-in-the-data-path.svg")


def ch12():
    d = D(980, 360, "Nowhere to send it", "A clean prompt and the same webhook: the sandboxed agent is refused by OpenShell, the plain pod has no exit in its tenant VRF")
    d.box(30, 80, 240, 90, "agent", "sandboxed assistant", ["OpenShell network policy", "allow-list: its AI route only"])
    d.box(30, 210, 240, 90, "bad", "plain pod (tenant-c)", ["no sandbox", "egress through TMM, VRF tenant-c"])
    d.box(340, 80, 200, 90, "dark", "OpenShell", ["NET:OPEN DENIED", "curl → 172.16.250.10:8080"], mono_lines=True)
    d.box(340, 210, 200, 90, "bnk", "TMM egress (tenant-c)", ["F5SPKEgress removed:", "no path, packet dropped"])
    d.box(620, 140, 150, 80, "fab", "border1 eth3.103", ["tcpdump: nothing"])
    d.box(820, 140, 130, 80, "plain", "client webhook", ["log stays empty"])
    d.arrow(270, 125, 340, 125, "", "#b45309", "4 3"); d.arrow(270, 255, 340, 255, "", "#b45309", "4 3")
    d.arrow(540, 255, 620, 190, "", LINE, "4 3"); d.arrow(770, 180, 820, 180, "", LINE, "4 3")
    d.note(30, 335, "Reachability is the last layer: when there is no route and no policy allowing it, content and identity do not matter.")
    d.save("12-nowhere-to-send-it.svg")


def ch13():
    d = D(980, 330, "On the record", "Four places, one timeline: who called what, which verdict TMM carried, what the sandbox refused, which egress existed")
    for i, (k, n, l) in enumerate([("bnk", "Polaris console", ["every model call", "key, tenant, model, tokens"]),
                                   ("bnk", "TMM", ["iRule verdicts", "X-Guardrail headers"]),
                                   ("dark", "OpenShell logs", ["NET:OPEN DENIED", "binary, destination, reason"]),
                                   ("ai", "Prometheus / Grafana", ["vllm:* per worker", "picker decisions, GPU use"])]):
        d.box(30 + i * 235, 80, 215, 100, k, n, l)
    d.box(30, 220, 920, 60, "plain", "the timeline of chapters 10 to 12, reconstructed from these four sources", [])
    for i in range(4):
        d.arrow(137 + i * 235, 180, 300 + i * 120, 220, "", LINE)
    d.note(30, 310, "One question to answer at the end: who tried it, when, with which key, and where exactly it stopped.")
    d.save("13-on-the-record.svg")


def ch14():
    d = D(980, 330, "Topology as a contract", "llm-d scores workers by where they sit (rack, rail); BNK's picker scores by cache and load. What each one knows")
    d.box(30, 80, 260, 110, "bnk", "F5EPP scorers", ["prefix-cache · prefill load", "queue depth · KV usage", "no rack, no rail, no NIC"])
    d.box(340, 80, 260, 110, "ai", "llm-d inference scheduler", ["topology-aware P/D pairing", "labels on the pods", "the router must see the layout"])
    d.box(650, 80, 300, 110, "plain", "mocker pods, labelled", ["topology.kubernetes.io/rack", "factory.lab/rail", "what a topology scorer would read"], mono_lines=True)
    d.arrow(290, 135, 340, 135, "vs", LINE, "4 3"); d.arrow(600, 135, 650, 135, "", LINE, "4 3")
    d.note(30, 240, "Optional chapter: label the workers, read the picker's config, and see which signals reach the router today and which do not.")
    d.save("14-topology-as-a-contract.svg")


if __name__ == "__main__":
    for f in (ch01, ch02, ch03, ch04, ch05, ch06, ch07, ch08, ch09, ch10, ch11, ch12, ch13, ch14):
        f()
    print("wrote 14 diagrams in", HERE)
