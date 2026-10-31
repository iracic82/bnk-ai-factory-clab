#!/usr/bin/env python3
# Scene cards in the style of the bnk-ai-gateway track: dark background, a kicker, a title, one sentence of
# subtitle, dark panels with the one that matters outlined in F5 red, labelled arrows, a legend. One PNG per
# chapter (SVG drawn here, rendered with cairosvg), 1200 x 600.
# Re-run: python3 instruqt/bnk-ai-factory-clab/assets/scenes.py
import os
import cairosvg

HERE = os.path.dirname(os.path.abspath(__file__))
BG, PANEL, CARD, LINE = "#0e1116", "#141a23", "#1b2230", "#2a3444"
TXT, SUB, DIM = "#e6e9ef", "#aab4c3", "#7d8899"
RED, BLUE, GREEN, ORANGE, PURPLE = "#e4002b", "#58a6ff", "#7ee787", "#f0a040", "#c792ea"
SANS = "Inter, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "'JetBrains Mono', Consolas, Menlo, monospace"
W, H = 1200, 600


def esc(t): return str(t).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class Scene:
    def __init__(self, kicker, title, sub):
        self.o = [f'<rect width="{W}" height="{H}" fill="{BG}"/>']
        self.t(30, 34, kicker.upper(), 11.5, DIM, 600, mono=True, spacing=2)
        self.t(30, 70, title, 26, TXT, 700)
        for i, line in enumerate(sub if isinstance(sub, list) else [sub]):
            self.t(30, 96 + i * 19, line, 14, SUB)

    def t(self, x, y, s, size, color, weight=400, anchor="start", mono=False, spacing=0):
        f = MONO if mono else SANS
        sp = f' letter-spacing="{spacing}"' if spacing else ""
        self.o.append(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" text-anchor="{anchor}" font-family="{f}"{sp}>{esc(s)}</text>')

    def panel(self, x, y, w, h, label):
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{PANEL}" stroke="{LINE}" stroke-width="1.5"/>')
        self.t(x + 16, y + 24, label.upper(), 11, DIM, 600, mono=True, spacing=1.5)

    def card(self, x, y, w, h, title, lines=(), hot=False, color=None, title_color=None):
        stroke = color or (RED if hot else LINE)
        self.o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="9" fill="{CARD}" stroke="{stroke}" stroke-width="{2.5 if (hot or color) else 1.2}"/>')
        self.t(x + 16, y + 26, title, 14, title_color or (RED if hot else TXT), 700)
        for i, l in enumerate(lines):
            self.t(x + 16, y + 47 + i * 18, l, 12, SUB, mono=True)

    def arrow(self, x1, y1, x2, y2, color=BLUE, label="", dash=False, w=2.5):
        d = ' stroke-dasharray="6 5"' if dash else ""
        mid = f'a{abs(hash((x1, y1, x2, y2))) % 100000}'
        self.o.append(f'<defs><marker id="{mid}" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L10,4 L0,8 z" fill="{color}"/></marker></defs>')
        self.o.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{w}"{d} marker-end="url(#{mid})"/>')
        if label:
            self.t((x1 + x2) / 2, (y1 + y2) / 2 - 8, label, 11.5, color, 600, "middle", mono=True)

    def legend(self, items, y=H - 26):
        x = 30
        for color, bold, rest in items:
            self.o.append(f'<rect x="{x}" y="{y - 11}" width="12" height="12" rx="2" fill="{color}"/>')
            self.o.append(f'<text x="{x + 18}" y="{y}" font-size="12.5" fill="{SUB}" font-family="{SANS}"><tspan fill="{TXT}" font-weight="700">{esc(bold)}</tspan> {esc(rest)}</text>')
            x += 40 + 7.2 * (len(bold) + len(rest))

    def save(self, name):
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">' + "".join(self.o) + "</svg>"
        cairosvg.svg2png(bytestring=svg.encode(), write_to=os.path.join(HERE, name), output_width=W * 2, output_height=H * 2)


def c01():
    s = Scene("Chapter 1 · One VM, a whole factory", "Northlight's factory, outside in", ["One VM. A spine/leaf fabric speaking BGP EVPN, an exit router, a client, and a kind cluster whose worker is cabled into leaf1.", "TMM, BNK's data plane, has a leg on that cable and peers with the fabric like any router would."])
    s.panel(30, 130, 560, 400, "the fabric · containerlab, FRR")
    s.card(50, 170, 120, 72, "client", ["172.16.250.10", "the internet"])
    s.card(200, 170, 110, 72, "r5", ["exit, AS 65500", "VRF-lite in"])
    s.card(340, 170, 120, 72, "border1", ["4 VRFs, L3VNI", "type-5 out"])
    s.card(490, 150, 80, 48, "spine1", [], color=LINE); s.card(490, 220, 80, 48, "spine2", [], color=LINE)
    s.card(340, 290, 120, 72, "leaf1", ["VRF external", "+ tenant-a/b/c"])
    s.card(340, 400, 230, 100, "handoff: leaf1 eth3 <-> bnk-worker eth1", ["untagged = external (172.16.10.0/24)", "VLAN 101/102/103 = tenant VRFs", "one veth, four BGP sessions"], hot=True)
    s.arrow(170, 206, 200, 206); s.arrow(310, 206, 340, 206); s.arrow(460, 190, 490, 180); s.arrow(490, 250, 460, 300, label="EVPN")
    s.arrow(400, 362, 400, 400, RED)
    s.panel(620, 130, 550, 400, "the cluster · kind v1.35, BNK 2.4.2")
    s.card(640, 170, 240, 110, "bnk-worker", ["eth1 -> leaf1 eth3, hugepages 2 Mi"])
    s.card(660, 222, 200, 50, "TMM · AS 65100", ["self IP .11 on every VLAN"], hot=True)
    s.card(900, 170, 250, 110, "bnk-worker2 · bnk-control-plane", ["AI workloads, 4 fake H100", "Calico, Multus, the operator"])
    s.card(640, 310, 510, 96, "BNK · CNEInstance 2.4.2, Available=True", ["f5-cne-controller, Polaris AI Gateway, F5BnkGateway pool 172.16.100.10-29", "Vrf, F5SPKVlan, RoutingConfig: the network model that carries EVPN"])
    s.card(640, 430, 510, 70, "one request: client > r5 > border1 > leaf1 > TMM > Aurora's hello pod", ["GET http://10.201.100.10/   HTTP 200   (VIP in VRF tenant-a)"])
    s.arrow(570, 450, 640, 465, GREEN, w=3)
    s.legend([(BLUE, "fabric", "routes you read on each hop"), (RED, "the handoff", "where a pod's data plane becomes a fabric port"), (GREEN, "the request", "crosses all of it")])
    s.save("scene-01.png")


if __name__ == "__main__":
    c01()
    print("wrote scene-01.png")
