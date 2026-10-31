#!/usr/bin/env python3
"""The Lab Topology tab: a live picture of the factory on this VM.

Serves /topology (the page, scripts/topology.html next to this file) and /api/topology (JSON: nodes and edges
with live state). State comes from what the learner can also query by hand: docker ps for the containerlab
nodes, kubectl for the cluster, leaf1's vtysh for the BGP sessions, the openshell CLI for the sandboxes.
Standard library only; refreshed at most every 5 seconds, so the page may poll freely.

    python3 topology-api.py --bind 0.0.0.0 --port 5050
"""
import argparse
import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
KUBECONFIG = os.environ.get("KUBECONFIG", "/root/lab/clab/kubeconfig")
_cache = {"at": 0.0, "data": None}
_lock = threading.Lock()


def sh(args, timeout=12):
    try:
        env = dict(os.environ, KUBECONFIG=KUBECONFIG)
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=env).stdout
    except Exception:
        return ""


def kget(args):
    out = sh(["kubectl"] + args + ["-o", "json"])
    try:
        return json.loads(out).get("items", [])
    except Exception:
        return []


def containers():
    up = set()
    for line in sh(["docker", "ps", "--format", "{{.Names}} {{.Status}}"]).splitlines():
        name, _, status = line.partition(" ")
        if status.startswith("Up"):
            up.add(name)
    return up


def bgp_leaf1():
    """Established peers on leaf1 per VRF, from vtysh JSON."""
    out = sh(["docker", "exec", "leaf1", "vtysh", "-c", "show bgp vrf all summary json"])
    est = {}
    try:
        for vrf, fam in json.loads(out).items():
            for af in fam.values():
                for peer, s in (af.get("peers") or {}).items():
                    if s.get("state") == "Established":
                        est.setdefault(vrf, set()).add(peer)
    except Exception:
        pass
    return {k: sorted(v) for k, v in est.items()}


def pods(ns, selector=None):
    args = ["-n", ns, "get", "pods"]
    if selector:
        args += ["-l", selector]
    return kget(args)


def ready(p):
    return p.get("status", {}).get("phase") == "Running" and all(c.get("ready") for c in p.get("status", {}).get("containerStatuses", []))


def gateways():
    g = {}
    for it in kget(["get", "gateways", "-A"]):
        conds = {c["type"]: c["status"] for c in it.get("status", {}).get("conditions", [])}
        addr = (it.get("status", {}).get("addresses") or [{}])[0].get("value") or (it["spec"].get("addresses") or [{}])[0].get("value", "")
        g[f'{it["metadata"]["namespace"]}/{it["metadata"]["name"]}'] = {"addr": addr, "programmed": conds.get("Programmed") == "True"}
    return g


def agents():
    a = []
    for it in kget(["get", "agents.kagent.dev", "-A"]):
        conds = {c["type"]: c["status"] for c in it.get("status", {}).get("conditions", [])}
        a.append({"ns": it["metadata"]["namespace"], "name": it["metadata"]["name"], "ready": conds.get("Ready") == "True"})
    return a


def sandboxes():
    s = {}
    for line in sh(["openshell", "sandbox", "list"]).splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2:
            s[parts[0]] = parts[-1]
    return s


def build():
    up = containers()
    bgp = bgp_leaf1()
    gw = gateways()
    ag = agents()
    sb = sandboxes()
    tmm = pods("f5-bnk", "app=f5-tmm")
    tmm_ok = bool(tmm) and ready(tmm[0])
    ctrl = pods("f5-bnk", "app=f5-cne-controller")
    picker = pods("aigw-models", "app=model-pool-epp")
    mocker = [p for p in pods("aigw-models") if "mocker" in p["metadata"]["name"]]
    aigw = pods("f5-bnk")
    polaris_ok = any("aigateway" in p["metadata"]["name"] and ready(p) for p in aigw)
    ate = pods("ate-system")
    nodes, edges = [], []

    def n(id, label, group, ok=None, title=""):
        nodes.append({"id": id, "label": label, "group": group, "ok": ok, "title": title})

    def e(a, b, label="", ok=None, dashes=False):
        edges.append({"from": a, "to": b, "label": label, "ok": ok, "dashes": dashes})

    # fabric
    for name, lab in [("client", "client\n172.16.250.10"), ("r5", "r5\nAS 65500"), ("border1", "border1\nVRF-lite"),
                      ("spine1", "spine1"), ("spine2", "spine2"), ("leaf1", "leaf1\nAS 65201"), ("leaf2", "leaf2\nAS 65202")]:
        n(name, lab, "fabric", name in up, f"containerlab node {name}: {'up' if name in up else 'down'}")
    e("client", "r5"); e("r5", "border1", "VLAN 200/101-103"); e("border1", "spine1"); e("border1", "spine2")
    e("spine1", "leaf1"); e("spine2", "leaf1"); e("spine1", "leaf2"); e("spine2", "leaf2")
    # cluster
    for name in ["bnk-control-plane", "bnk-worker", "bnk-worker2"]:
        n(name, name, "node", name in up, f"kind node {name}")
    n("tmm", "TMM\n172.16.10.11", "bnk", tmm_ok, "f5-tmm on bnk-worker: " + ("Ready" if tmm_ok else "not Ready"))
    e("leaf1", "bnk-worker", "eth3 → eth1", "bnk-worker" in up)
    e("leaf2", "bnk-worker2", "eth3 → eth1", "bnk-worker2" in up, True)
    e("bnk-worker", "tmm")
    ext = bgp.get("default", []) + bgp.get("external", [])
    e("tmm", "leaf1", "BGP default" if ext else "BGP down", bool(ext))
    n("ctrl", "f5-cne-controller", "bnk", bool(ctrl) and ready(ctrl[0]), "the BNK controller")
    e("ctrl", "tmm", "gRPC", None, True)
    # tenants
    for t, disp, vlan in [("a", "Aurora Health", 101), ("b", "Borealis Bank", 102), ("c", "Cobalt Labs", 103)]:
        vrf = f"tenant-{t}"
        peers = bgp.get(vrf, [])
        n(vrf, f"{disp}\nVRF {vrf}", "tenant", bool(peers), f"VLAN {vlan} leg; leaf1 peers: {', '.join(peers) or 'none'}")
        e("tmm", vrf, f"VLAN {vlan} BGP", bool(peers))
        e(vrf, "border1", "type-5", bool(peers), True)
        g = gw.get(f"f5-bnk/{vrf}-ai", {})
        n(f"{vrf}-ai", f"AI route\n{g.get('addr', '')}", "route", g.get("programmed"), f"Polaris route {vrf}-ai")
        e(vrf, f"{vrf}-ai", "", g.get("programmed"), True)
        for a in ag:
            if a["ns"] == vrf:
                n(f"{vrf}/{a['name']}", f"{a['name']}\n({vrf})", "agent" if a["name"] == "assistant" else "shadow", a["ready"], f"kagent Agent {vrf}/{a['name']}")
                e(f"{vrf}/{a['name']}", f"{vrf}-ai", "model", a["ready"])
        sbname = f"{vrf}-agent"
        if sbname in sb:
            n(f"sb-{vrf}", f"OpenShell\n{sbname}", "sandbox", sb[sbname] == "Ready", f"sandbox phase {sb[sbname]}")
            e(f"sb-{vrf}", f"{vrf}-ai", "key injected", sb[sbname] == "Ready", True)
    # AI layer
    n("polaris", "Polaris\nAI Gateway", "ai", polaris_ok, "f5-aigateway pods")
    n("picker", "F5EPP picker", "ai", bool(picker) and ready(picker[0]), "model-pool-epp")
    n("mocker", f"Dynamo mocker\n{sum(1 for p in mocker if ready(p))}/{len(mocker)} pods", "ai", bool(mocker) and all(ready(p) for p in mocker), "DynamoGraphDeployment mocker")
    n("ollama", "ollama (VM)\nqwen2.5", "ai", "lab-ollama" in up, "docker container lab-ollama")
    e("tmm", "polaris", "", polaris_ok, True); e("polaris", "picker", "pool VIP .12"); e("picker", "mocker"); e("polaris", "ollama")
    for t in "abc":
        e(f"tenant-{t}-ai", "polaris", "", None, True)
    # substrate
    ate_ok = bool(ate) and all(ready(p) for p in ate if p["status"].get("phase") != "Succeeded")
    n("substrate", f"Agent Substrate\n{len(ate)} pods", "substrate", ate_ok if ate else None, "ate-system")
    e("substrate", "bnk-worker2", "", None, True)
    return {"generated": time.strftime("%H:%M:%S UTC", time.gmtime()), "nodes": nodes, "edges": edges,
            "summary": {"containers_up": len(up), "bgp": {k: len(v) for k, v in bgp.items()}, "agents": len(ag), "sandboxes": len(sb)}}


def data():
    with _lock:
        if time.time() - _cache["at"] > 5 or _cache["data"] is None:
            _cache["data"] = build()
            _cache["at"] = time.time()
        return _cache["data"]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/topology"):
            self._send(200, open(os.path.join(HERE, "topology.html"), "rb").read(), "text/html; charset=utf-8")
        elif path == "/api/topology":
            self._send(200, json.dumps(data()).encode(), "application/json")
        else:
            self._send(404, b"not found", "text/plain")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5050)
    a = ap.parse_args()
    ThreadingHTTPServer((a.bind, a.port), H).serve_forever()
