#!/usr/bin/env python3
# Scene cards for the chapters, in the style of the bnk-ai-gateway track: dark background, a kicker, a title,
# one line of subtitle, rows of dark cards with the one that matters outlined in F5 red, arrows between
# neighbours, a legend. 1200 x 600, rendered at 2x with cairosvg.
#
# Layout is a grid: row(y, h, cards) spreads the cards evenly across the width. Every card is measured against
# its text and the script refuses to render a card whose title or lines would not fit, so nothing overlaps.
# Re-run: python3 instruqt/bnk-ai-factory-clab/assets/scenes.py
import os
import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
BG, PANEL, CARD, LINE = "#0e1116", "#141a23", "#1b2230", "#2a3444"
TXT, SUB, DIM = "#e6e9ef", "#aab4c3", "#7d8899"
RED, BLUE, GREEN, ORANGE, PURPLE, YELLOW, PINK = "#e4002b", "#58a6ff", "#7ee787", "#f0a040", "#c792ea", "#ffd166", "#ff5c7a"
SANS = "Inter, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "'JetBrains Mono', Consolas, Menlo, monospace"
W, H = 1200, 600
M = 30                       # page margin
PAD = 16                     # card padding
MONO_W, SANS_W = 7.4, 8.6    # px per char at 12 px mono and 14 px bold sans, measured generously


def esc(t): return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Scene:
    def __init__(self, kicker, title, sub):
        self.o = [f'<rect width="{W}" height="{H}" fill="{BG}"/>']
        self.t(M, 34, kicker.upper(), 11.5, DIM, 600, mono=True, spacing=2)
        self.t(M, 70, title, 26, TXT, 700)
        assert len(sub) * 7.6 <= W - 2 * M, f"subtitle too long: {sub}"
        self.t(M, 97, sub, 14, SUB)

    def t(self, x, y, s, size, color, weight=400, anchor="start", mono=False, spacing=0):
        f = MONO if mono else SANS
        sp = f' letter-spacing="{spacing}"' if spacing else ""
        self.o.append(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}" font-family="{f}"{sp}>{esc(s)}</text>')

    def card(self, x, y, w, h, title, lines=(), hot=False, color=None, dash=False):
        need_w = max([len(title) * SANS_W] + [len(l) * MONO_W for l in lines]) + 2 * PAD
        need_h = 36 + 18 * len(lines) + 6
        assert need_w <= w, f"card '{title}' needs {need_w:.0f}px, has {w}px"
        assert need_h <= h, f"card '{title}' needs {need_h}px high, has {h}px"
        stroke = color or (RED if hot else LINE)
        d = ' stroke-dasharray="6 4"' if dash else ""
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="9" fill="{CARD}" stroke="{stroke}" stroke-width="{2.4 if (hot or color) else 1.2}"{d}/>')
        self.t(x + PAD, y + 26, title, 14, RED if hot else TXT, 700)
        for i, l in enumerate(lines):
            self.t(x + PAD, y + 48 + i * 18, l, 12, SUB, mono=True)

    def row(self, y, h, cards, gap=24, x0=M, x1=W - M, arrows=None):
        """cards: list of (title, lines, opts); spreads them over [x0, x1]. arrows: list per gap of
        (color, label) or None. Returns the x centres."""
        n = len(cards)
        w = (x1 - x0 - gap * (n - 1)) / n
        centres = []
        for i, (title, lines, opts) in enumerate(cards):
            x = x0 + i * (w + gap)
            self.card(x, y, w, h, title, lines, **opts)
            centres.append(x + w / 2)
            if arrows and i < n - 1 and arrows[i]:
                col, lab = arrows[i]
                self.arrow(x + w, y + h / 2, x + w + gap, y + h / 2, col, w=3)
                if lab:   # above the row, centred on the gap, where it cannot touch a card
                    self.t(x + w + gap / 2, y - 7, lab, 11, col, 600, "middle", mono=True)
        return centres

    def arrow(self, x1, y1, x2, y2, color=BLUE, label="", dash=False, w=2.5):
        d = ' stroke-dasharray="6 5"' if dash else ""
        mid = f'a{abs(hash((x1, y1, x2, y2, color))) % 1000000}'
        self.o.append(f'<defs><marker id="{mid}" markerWidth="9" markerHeight="7" refX="8" refY="3.5" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L9,3.5 L0,7 z" fill="{color}"/></marker></defs>')
        self.o.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{w}"{d} marker-end="url(#{mid})"/>')
        if label:
            self.t((x1 + x2) / 2, min(y1, y2) - 10, label, 11, color, 600, "middle", mono=True)

    def down(self, x, y1, y2, color=BLUE, label=""):
        self.arrow(x, y1, x, y2, color, w=3)
        if label:   # beside the arrow, on the side with room
            if x > W / 2: self.t(x - 10, (y1 + y2) / 2 + 4, label, 11, color, 600, "end", mono=True)
            else: self.t(x + 10, (y1 + y2) / 2 + 4, label, 11, color, 600, mono=True)

    def strip(self, y, h, title, lines=(), **opts):
        self.card(M, y, W - 2 * M, h, title, lines, **opts)

    def legend(self, items, y=H - 24):
        x = M
        for color, bold, rest in items:
            self.o.append(f'<rect x="{x}" y="{y - 11}" width="12" height="12" rx="2" fill="{color}"/>')
            self.o.append(f'<text x="{x + 18}" y="{y}" font-size="12.5" fill="{SUB}" font-family="{SANS}"><tspan fill="{TXT}" font-weight="700">{esc(bold)}</tspan> {esc(rest)}</text>')
            x += 44 + 7.0 * (len(bold) + len(rest))
        assert x <= W, "legend too long"

    def save(self, name):
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" width="{W}" height="{H}" viewBox="0 0 {W} {H}">' + "".join(self.o) + "</svg>"
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(HERE, name), output_width=W * 2, output_height=H * 2)


# Rows: A at y=130 (h 120), B at y=285 (h 110), C strip at y=430 (h 110), legend at 576.
A, AH, B, BH, C, CH = 130, 120, 285, 110, 430, 110


def c01():
    s = Scene("Chapter 1 · One VM, a whole factory", "Northlight's factory, outside in",
              "A client behind an exit router, a BGP EVPN fabric, a kind cluster cabled into leaf1, and BNK's data plane peering with it like a router.")
    s.row(A, AH, [("client", ["172.16.250.10", "stands in for the internet"], {}),
                  ("r5 · exit router", ["AS 65500", "VRF-lite to border1"], {}),
                  ("border1 + spines", ["4 VRFs as L3VNI", "EVPN type-5 to leaf1"], {}),
                  ("leaf1", ["VRF external + tenant-a/b/c", "eth3: the handoff"], {})],
          arrows=[(BLUE, ""), (BLUE, ""), (BLUE, "EVPN")])
    s.down(1027, A + AH, B, RED, "one veth, four BGP sessions")
    s.row(B, BH, [("BNK · CNEInstance 2.4.2", ["Available=True", "controller, Polaris, VIP pool"], {}),
                  ("kind · bnk-worker2, control-plane", ["AI workloads, 4 fake H100", "Calico, Multus, operator"], {}),
                  ("TMM on bnk-worker · AS 65100", ["untagged = VRF external", "VLAN 101/102/103 = tenants"], {"hot": True})],
          arrows=[None, None])
    s.strip(C, CH, "one request across all of it",
            ["client > r5 > border1 > leaf1 > TMM > Aurora's hello pod", "GET http://10.201.100.10/   HTTP 200   (a VIP inside VRF tenant-a)", "and the /32 for it in r5's table, border1's VRF and leaf1's EVPN routes"], color=GREEN)
    s.legend([(BLUE, "fabric", "routes you read on each hop"), (RED, "the handoff", "where a pod's data plane becomes a fabric port"), (GREEN, "the request", "crosses all of it")])
    s.save("scene-01.png")


def c02():
    s = Scene("Chapter 2 · Three tenants", "Aurora, Borealis and Cobalt, each on its own rails",
              "One declaration per tenant becomes a VRF on TMM, a VLAN to leaf1, a VIP pool, a SNAT pool and a Polaris tenant with its own key.")
    s.row(A, AH, [("Aurora Health · tenant-a", ["VRF tenant-a · VLAN 101", "VIPs 10.201.100.0/24", "Polaris key, route .20"], {"color": GREEN}),
                  ("Borealis Bank · tenant-b", ["VRF tenant-b · VLAN 102", "VIPs 10.202.100.0/24", "Polaris key, route .21"], {"color": BLUE}),
                  ("Cobalt Labs · tenant-c", ["VRF tenant-c · VLAN 103", "VIPs 10.203.100.0/24", "Polaris key, route .22"], {"color": ORANGE})])
    for x, col in ((220, GREEN), (600, BLUE), (980, ORANGE)):
        s.down(x, A + AH, B, col)
    s.strip(B, 60, "TMM · one data plane, three route domains · a tenant is a route domain, not a pod", [], hot=True)
    s.row(C, CH, [("leaf1 · VRF tenant-b", ["from-tmm-tenant-b permits", "VIP pool and SNAT pool only"], {}),
                        ("border1 -> r5 · VRF-lite", ["eth3.102 <-> r5", "r5 sends a default back"], {}),
                        ("what you add", ["F5VirtualServer tenant-b-reports", "10.202.100.11 · reachable in ~10 s"], {"color": BLUE})],
          arrows=[(BLUE, ""), (BLUE, "")])
    s.legend([(GREEN, "tenant-a", "Aurora Health"), (BLUE, "tenant-b", "Borealis Bank, where you publish today"), (ORANGE, "tenant-c", "Cobalt Labs"), (RED, "TMM", "three route domains")])
    s.save("scene-02.png")


def c03():
    s = Scene("Chapter 3 · GPUs without GPUs", "Eight H100s this VM does not have",
              "The fake GPU operator advertises nvidia.com/gpu, KAI schedules tenants against it, and the Dynamo mocker publishes vLLM metrics.")
    s.row(A, AH, [("bnk-worker · bnk-worker2", ["nvidia.com/gpu: 4 + 4", "product H100, no driver, no card"], {}),
                  ("KAI queue ai-factory", ["tenant-a quota 4, weight 2", "tenant-b 2 · tenant-c 2 · limit -1"], {"hot": True}),
                  ("Dynamo mocker x2", ["Qwen3-0.6B tokenizer, no weights", "dynamo_component_inflight_requests"], {"color": ORANGE})])
    s.down(600, A + AH, B, RED)
    s.row(B, BH, [("1 · fill it", ["Aurora 4, Borealis 2, Cobalt 2", "all eight in use"], {"color": GREEN}),
                  ("2 · Cobalt asks for 4 more", ["Pending: over quota,", "nothing idle to borrow"], {"color": YELLOW}),
                  ("3 · Aurora's job ends", ["Cobalt's job takes the idle 4", "borrowed, reclaimable"], {"color": BLUE})],
          arrows=[(DIM, ""), (DIM, "")])
    s.strip(C, CH, "what a pod and Grafana see",
            ["inside a scheduled pod: a fake nvidia-smi reports an H100 at 90 percent, memory in use", "Grafana: dynamo_component_inflight_requests and DCGM_FI_DEV_GPU_UTIL, real counters on simulated hardware"])
    s.legend([(RED, "the scheduler", "fairness between tenants"), (GREEN, "quota", "guaranteed"), (BLUE, "borrowed", "reclaimable"), (ORANGE, "metrics", "without a GPU")])
    s.save("scene-03.png")


def c04():
    s = Scene("Chapter 4 · The picker", "TMM asks before it forwards",
              "The pool VIP's HTTPRoute ends in an InferencePool. For every request TMM asks F5's Endpoint Picker which worker should take it.")
    s.row(A, AH, [("client", ["POST /v1/chat/completions", "172.16.100.12:8000"], {}),
                  ("TMM · pool VIP", ["HTTPRoute -> InferencePool", "ext-proc call per request"], {"hot": True}),
                  ("F5EPP · engine dynamo", ["prefix-cache, prefill-load,", "queue, kv-cache scorers"], {"color": PURPLE}),
                  ("NATS", ["KV cache events", "prefix -> worker map"], {})],
          arrows=[(GREEN, "1"), (PURPLE, "2 which one?"), (DIM, "")])
    s.down(432, A + AH, B, GREEN, "3 to the worker the picker named")
    s.row(B, BH, [("Dynamo mocker-0", ["KV cache: prefixes it has seen", "dynamo_component_inflight_requests"], {"color": ORANGE}),
                  ("Dynamo mocker-1", ["KV cache: prefixes it has seen", "dynamo_component_inflight_requests"], {"color": ORANGE})], x1=W / 2 + 80)
    s.card(W / 2 + 120, B, W - M - W / 2 - 120, BH, "F5EPP spec.mode", ["aggregated: one worker end to end", "disaggregated: prefill + decode", "chapter 14 comes back to this"])
    s.strip(C, CH, "what you watch",
            ["the picker's log names a worker per request · the same prompt twice lands on the same worker", "twelve long prompts in flight push the next short one to the other worker · Prometheus shows the load per pod"])
    s.legend([(GREEN, "request", "through the pool VIP"), (PURPLE, "ext-proc", "TMM's question, the picker's answer"), (ORANGE, "workers", "real KV-cache bookkeeping"), (RED, "TMM", "forwards where it is told")])
    s.save("scene-04.png")


def c05():
    s = Scene("Chapter 5 · Sessions that stick", "Persistence that reads the protocol",
              "Aurora's MCP server gets its own Gateway on 172.16.100.23. Three replicas, one session: without help the calls scatter.")
    s.row(A, AH, [("client", ["initialize -> Mcp-Session-Id", "tools/call x6, same id"], {}),
                  ("Gateway tenant-mcp · .23", ["HTTPRoute /mcp -> agent:8001", "NetPolicy tenant-mcp-sessions"], {"hot": True}),
                  ("F5BigPersistenceProfile", ["type MODEL_CONTEXT_PROTOCOL", "Secret mcp-passphrase"], {"color": GREEN}),
                  ("agent x3", ["before: 6 calls, 2-3 pods", "after: 6 calls, 1 pod"], {"color": GREEN})],
          arrows=[(GREEN, "session"), (GREEN, "attached"), (GREEN, "sticks")])
    s.row(B, BH, [("the same for A2A · .14", ["type AGENT2AGENT", "message/send, then tasks/get", "NetPolicy next to it in f5-bnk"], {"color": PURPLE}),
                  ("the attachment shape", ["NetPolicy: targetRef Gateway + listener", "extensionRefs: BNK extensions", "one per listener, same namespace"], {})])
    s.strip(C, CH, "what you measure",
            ["scale deploy/agent to 3 · one initialize, six tools/call with the same id, the pod name from each answer", "uniq -c before the Secret exists and after: TMM read the session id from the protocol, not from a cookie"])
    s.legend([(GREEN, "MCP", "session id in the protocol"), (PURPLE, "A2A", "the second persistence type"), (RED, "the listener", "where the profile lives")])
    s.save("scene-05.png")


def c06():
    s = Scene("Chapter 6 · The programmable data path", "Where the CRDs stop, Tcl continues",
              "An F5BigCneIrule runs inside TMM on the listener's events: it answers /factory/whoami itself and stamps every other request.")
    s.row(A, AH, [("client", ["GET /factory/whoami", "POST /mcp"], {}),
                  ("TMM · listener on .23", ["NetPolicy, two extensions:", "persistence profile + iRule"], {"hot": True}),
                  ("answered in TMM", ["200, JSON from Tcl", "X-Factory-Tenant: tenant-a"], {"color": GREEN}),
                  ("forwarded to the pod", ["/mcp still gets a session id", "request carries the stamp"], {"color": BLUE})],
          arrows=[(GREEN, ""), (GREEN, "whoami"), (BLUE, "mcp")])
    s.row(B, BH, [("change it live", ["sed + kubectl apply", "picked up in ~8 s", "no restart, no gap"], {"color": ORANGE}),
                  ("the Access CRDs", ["f5-big-access-jwt-configs", "issuer, keys, claims", "no IdP in this VM: read only"], {"color": PURPLE})])
    s.strip(C, CH, "one listener · one NetPolicy · two extensions",
            ["the NetPolicy from chapter 5 gains an extensionRef; a listener takes one NetPolicy, a NetPolicy takes several extensions", "identity checks have a home at the traffic layer; the IdP is the only thing missing here"])
    s.legend([(GREEN, "in TMM", "no pod involved"), (BLUE, "forwarded", "with the stamp"), (ORANGE, "live change", "apply and it is there"), (PURPLE, "identity CRDs", "waiting for an IdP")])
    s.save("scene-06.png")


def c07():
    s = Scene("Chapter 7 · Agent Substrate", "Agents are not pods",
              "A scheduler of their own: WorkerPools, golden snapshots, actors forked from them, identities from PodCertificateRequest.")
    s.row(A, AH, [("ate-system", ["api-server, controller", "atelet on every node"], {}),
                  ("atenet-router", ["the actor's only network", "-> the tenant's AI route"], {"color": PURPLE}),
                  ("WorkerPool kagent-default", ["replicas 2", "ateom-gvisor v0.0.9"], {}),
                  ("identities", ["PodCertificateRequest", "certificates.k8s.io/v1beta1"], {})])
    s.row(B, BH, [("SandboxAgent concierge", ["Northlight's front desk", "no tools, lab tenant's model", "workerPoolRef kagent-default"], {"hot": True}),
                  ("ActorTemplate", ["generated by kagent", "Substrate builds the snapshot"], {"color": ORANGE}),
                  ("actor on a worker", ["forked from the snapshot", "Ready in the agent's status", "listed in the kagent tab"], {"color": GREEN})],
          arrows=[(ORANGE, "kagent"), (GREEN, "fork")])
    s.strip(C, CH, "what changes",
            ["a pod is pulled, started and torn down by the kubelet; an actor is forked from a snapshot that already has the runtime loaded", "kagent owns the agent, Substrate owns the worker and the snapshot; the actor has no cluster network, only the router"])
    s.legend([(RED, "SandboxAgent", "the one YAML you apply"), (ORANGE, "generated", "template and snapshot"), (GREEN, "actor", "running, no Deployment"), (PURPLE, "router", "the only way out")])
    s.save("scene-07.png")


def c08():
    s = Scene("Chapter 8 · OpenShell", "A key the agent never had",
              "The sanctioned assistants run in NVIDIA OpenShell sandboxes. A provider injects the key on the way out, towards one address only.")
    s.row(A, AH, [("sandbox tenant-a-agent", ["no key in its environment", "policy per binary, per host"], {"hot": True}),
                  ("provider f5-aigw-tenant-a", ["endpoint 172.16.100.20:80", "credential: Aurora's key"], {}),
                  ("Aurora route .20", ["HTTP 200", "key present on arrival"], {"color": GREEN}),
                  ("Borealis route .21", ["DENIED in the kernel", "logged with the binary"], {"color": PINK})],
          arrows=[(DIM, ""), (GREEN, "allowed"), (PINK, "refused")])
    s.row(B, BH, [("policy update --wait", ["add 172.16.100.21:80 for curl", "hot-reloaded while it runs", "now: packet out, Polaris 401"], {"color": ORANGE}),
                  ("policy set --wait", ["put the base policy back", "the refusal returns", "chapter 12 relies on this"], {"color": ORANGE})],
          arrows=[(ORANGE, "")])
    s.strip(C, CH, "the key lives in the provider, not in the sandbox",
            ["a copied key cannot leave because it was never there · two layers give two different refusals: the sandbox's DENIED and Polaris's 401", "openshell logs --source sandbox: every refused connection, with the binary and the destination"])
    s.legend([(GREEN, "allowed", "one endpoint, key injected"), (PINK, "DENIED", "in the kernel, logged"), (ORANGE, "policy", "changed while it runs"), (RED, "sandbox", "where the assistant lives")])
    s.save("scene-08.png")


def c09():
    s = Scene("Chapter 9 · Meet the agents", "Four agents, three tenants, one operator",
              "Each tenant's assistant has its own ModelConfig: its own route, its own key, its own model name. The operator sees the platform.")
    s.row(A, AH, [("tenant-a/assistant", ["tenant-a-qwen2.5-1.5b", "172.16.100.20 · aigw-key", "tools: Aurora's MCP"], {"color": GREEN}),
                  ("tenant-b/assistant", ["tenant-b-qwen2.5-1.5b", "172.16.100.21 · aigw-key", "tools: Borealis's MCP"], {"color": BLUE}),
                  ("tenant-c/assistant", ["tenant-c-qwen2.5-1.5b", "172.16.100.22 · aigw-key", "tools: Cobalt's MCP"], {"color": ORANGE}),
                  ("kagent/factory-operator", ["kubernetes tools, read-only", "sees pods, not tenant data"], {"color": PURPLE})])
    s.row(B, BH, [("A2A gateway · 172.16.100.14", ["/api/a2a/tenant-a/assistant/", "AGENT2AGENT persistence"], {"hot": True}),
                  ("Aurora's app · 172.16.100.16", ["POST /api/ask {question}", "the app calls its assistant"], {}),
                  ("Polaris · the record", ["tenant-a · tenant-a-app-key", "tokens per call; refusals too"], {"color": GREEN})])
    s.strip(C, CH, "what you prove",
            ["an A2A call to Aurora's assistant lists the open clinical records through Aurora's MCP tools · the same through the published app", "Aurora's key on Aurora's route: 200 · Aurora's key on Borealis's route: refused by Polaris, and the model name does not exist there"])
    s.legend([(GREEN, "tenant-a", "Aurora"), (BLUE, "tenant-b", "Borealis"), (ORANGE, "tenant-c", "Cobalt"), (PURPLE, "operator", "platform, read-only"), (RED, "A2A", "the published front")])
    s.save("scene-09.png")


def c10():
    s = Scene("Chapter 10 · The agent nobody approved", "Sanctioned parts, no review",
              "A Cobalt developer deploys billing-reconciler as a plain pod: the sanctioned tools, Aurora's record lookup, and a POST to any URL.")
    s.row(A, AH, [("billing-reconciler", ["plain pod in tenant-c", "billing_export, lookup_record", "post_report to any URL"], {"color": YELLOW, "dash": True}),
                  ("TMM · route 172.16.100.22", ["Polaris checks key and model", "reads nothing else"], {"hot": True}),
                  ("Cobalt's egress", ["VRF tenant-c, VLAN 103", "SNAT 10.203.200.x"], {}),
                  ("webhook · client :8080", ["outside the factory", "MRNs, names, amounts"], {"color": PINK})],
          arrows=[(GREEN, "own key: 200"), (PINK, "post_report"), (PINK, "")])
    s.row(B, BH, [("attempt 1 · Aurora's key, copied", ["Polaris: 401, wrong tenant", "recorded under tenant-c"], {"color": PINK}),
                  ("attempt 2 · Cobalt's own key", ["every Cobalt developer has it", "the model follows the procedure"], {"color": GREEN}),
                  ("how it is reached", ["agents gateway publishes only", "the sanctioned three; kagent :8083"], {})])
    s.strip(C, CH, "where each layer stood",
            ["identity: necessary, not sufficient · content: nothing read the prompt or the answer · reachability: the pod leaves like any pod of Cobalt's", "leave it running: chapter 11 stops it in TMM, chapter 12 at the exit, chapter 13 writes it up"])
    s.legend([(YELLOW, "shadow agent", "sanctioned parts"), (PINK, "refused, then leaked", "wrong key, then out the door"), (GREEN, "passed", "with a legitimate key"), (RED, "TMM", "sees the route, not the content")])
    s.save("scene-10.png")


def c11():
    s = Scene("Chapter 11 · Guardrails in the data path", "A verdict before the model",
              "One NetPolicy puts the guardrails iRule on Cobalt's AI route. TMM asks the scanner over a sideband and answers flagged requests itself.")
    s.row(A, AH, [("caller · Cobalt's key", ["a clean question, or", "last night's export"], {"color": YELLOW}),
                  ("TMM · Gateway tenant-c-ai", ["NetPolicy guardrails-tenant-c", "iRule collects the body"], {"hot": True}),
                  ("CalypsoAI scanner", ["/backend/v1/scans", "passed | flagged"], {"color": PURPLE}),
                  ("model", ["sees passed requests only", "flagged never arrives"], {"color": GREEN})],
          arrows=[(GREEN, ""), (PURPLE, "sideband"), (GREEN, "passed")])
    s.row(B, BH, [("flagged", ["HTTP 200 answered by TMM", "X-Guardrail: blocked", "reads like a model reply"], {"color": PINK}),
                  ("the agent, rerun", ["same agent, key and task", "the export it read is flagged", "webhook count unchanged"], {"color": YELLOW}),
                  ("attach and detach", ["kubectl apply -f 50-attach-tenant-c", "same NetPolicy shape as ch 5 and 6", "kubectl delete -f takes it off"], {})])
    s.strip(C, CH, "content inspection where the content flows",
            ["in TMM, on the tenant's route, before the model · the verdict comes from the scanner, the enforcement and the record from the data plane", "chapter 12 is the case the scanner cannot see: a clean prompt"])
    s.legend([(GREEN, "passed", "to the model"), (PINK, "flagged", "answered in TMM"), (PURPLE, "scanner", "sideband from the iRule"), (YELLOW, "the shadow agent", "stopped without touching it")])
    s.save("scene-11.png")


def c12():
    s = Scene("Chapter 12 · Nowhere to send it", "A clean prompt and the same webhook",
              "Reachability is the last layer: the sandbox refuses the webhook by policy, and without its F5SPKEgress the plain pod has no first hop.")
    s.row(A, AH, [("sandbox tenant-c-agent", ["POST 172.16.250.10:8080", "no rule for it: DENIED"], {"color": PINK}),
                  ("the plain pod", ["billing-reconciler, no sandbox", "first 200, then no route"], {"color": YELLOW, "dash": True}),
                  ("F5SPKEgress tenant-c-egress", ["tunnel, route domain, SNAT", "delete it: no exit at all"], {"hot": True}),
                  ("border1 eth3.103 -> webhook", ["tcpdump on VLAN 103", "one POST, then silence"], {"color": BLUE})],
          arrows=[None, (YELLOW, "before"), (BLUE, "")])
    s.row(B, BH, [("still reachable", ["Cobalt's AI route 172.16.100.22", "internal leg, not egress", "sanctioned work unaffected"], {"color": GREEN}),
                  ("put it back the right way", ["kubectl apply -f 30-egress.yaml", "then delete the agent and its key", "a review question, not routing"], {})])
    s.strip(C, CH, "three layers, three catches",
            ["OpenShell: no connection the policy does not list, clean prompt or not · BNK: a tenant's exit exists because a declaration says so", "content inspection, identity and reachability each caught something the other two could not"])
    s.legend([(PINK, "DENIED", "in the sandbox"), (YELLOW, "plain pod", "no exit once the declaration is gone"), (BLUE, "VLAN 103", "where border1 would see it"), (GREEN, "AI route", "unaffected")])
    s.save("scene-12.png")


def c13():
    s = Scene("Chapter 13 · On the record", "Four sources, one timeline",
              "Nothing in the factory shares a log. Each layer keeps the record of the thing it enforces, and Mira writes the week up from all four.")
    s.row(A, AH, [("Polaris · the calls", ["refused with Aurora's key", "passed with Cobalt's key", "management API :18443"], {"color": GREEN}),
                  ("TMM · the verdicts", ["NetPolicy guardrails-tenant-c", "X-Guardrail: blocked", "the egress that was removed"], {"color": RED}),
                  ("OpenShell · the refusals", ["DENIED curl -> .21 (ch 8)", "DENIED curl -> webhook (ch 12)", "per sandbox, with the binary"], {"color": PINK}),
                  ("Prometheus · the load", ["dynamo inflight requests", "kai_queue_allocated_gpus", "Grafana for the picture"], {"color": ORANGE})])
    for x in (166, 455, 744, 1033):
        s.down(x, A + AH, B, DIM)
    s.strip(B, 150, "/root/incident-timeline.md · five lines, each with its source",
            ["1 deployed: billing-reconciler in tenant-c, outside any sandbox (kubectl, chapter 10)",
             "2 refused: Aurora's key on Cobalt's route (Polaris, 401)",
             "3 passed: Cobalt's own key; the export reached the webhook (Polaris, webhook log)",
             "4 stopped in TMM: verdict flagged, X-Guardrail: blocked (NetPolicy guardrails-tenant-c)",
             "5 clean POST: the sandbox refused it; the plain pod lost its exit (OpenShell log, border1)"], hot=True)
    s.strip(B + 170, 60, "'who tried it' is answerable in minutes because every control kept its own record", [])
    s.legend([(GREEN, "Polaris", "identity and tokens"), (RED, "TMM", "verdicts and declarations"), (PINK, "OpenShell", "refusals"), (ORANGE, "Prometheus", "load around it")])
    s.save("scene-13.png")


def c14():
    s = Scene("Chapter 14 · Topology as a contract (optional)", "What the picker can see, and what it cannot",
              "llm-d argues the router must know where workers sit, rack and rail. BNK's picker scores cache and load. Put the labels on and look.")
    s.row(A, AH, [("F5EPP · what it reads", ["KV events on NATS", "queue, prefill, kv-cache scorers"], {"hot": True}),
                  ("the workers, labelled", ["topology.kubernetes.io/rack", "factory.lab/rail · unread"], {"color": YELLOW, "dash": True}),
                  ("crosses into the router", ["cache state: yes · load: yes", "rack: no · rail: no"], {"color": PURPLE})],
          arrows=[(DIM, ""), (DIM, "")])
    s.row(B, BH, [("what you watch", ["the same prompt twice: the second", "lands where the cache is"], {}),
                  ("spec.mode", ["aggregated: one worker end to end", "disaggregated: prefill + decode"], {}),
                  ("where a scorer would go", ["next to the ones above", "fed by those labels, for P/D pairing"], {})])
    s.strip(C, CH, "the question for next quarter",
            ["the labels are the easy half; the plugin that reads them is the work", "no verdict on either project: a list of what reaches the picker in this factory and what does not"])
    s.legend([(RED, "picker", "cache and load aware"), (YELLOW, "labels", "placed, unread"), (PURPLE, "the boundary", "what the router is told")])
    s.save("scene-14.png")


if __name__ == "__main__":
    for f in (c01, c02, c03, c04, c05, c06, c07, c08, c09, c10, c11, c12, c13, c14):
        f()
    print("wrote scene-01.png .. scene-14.png")
