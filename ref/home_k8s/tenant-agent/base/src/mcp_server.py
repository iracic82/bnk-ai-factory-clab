"""Tenant MCP server: one tenant's business data plus tools that show how the tenant is wired into the AI factory.

Same transport as apps/agentic-app (MCP Streamable HTTP, JSON responses only, stdlib only). TENANT=a|b|c picks the
persona. Every network target is from a fixed list, so the model can't make the pod connect anywhere else.
"""
import json
import os
import socket
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TENANT = os.environ.get("TENANT", "a")
PORT = int(os.environ.get("MCP_PORT", "8001"))
MAX_BODY = 16384
VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]
INTERNET = "http://198.51.100.1/"   # R5's test internet; answers 401 to anyone who reaches it

# What the fabric gives each tenant (install/legacy/30-egress.yaml, 40-tenants-evpn.yaml, install/fabric/gen.py)
NET = {
    "a": {"vrf": "tenant-a", "vip": "10.201.100.10", "snat": ["172.16.201.10", "172.16.201.11", "172.16.201.12"],
          "published": "10.10.12.36", "gw_vip": "172.16.100.16", "ai_gw": "172.16.100.20", "vni": 10001, "vip_vtep": "TMM (L3VNI 10001)", "dpu_leg": "VLAN 101", "exit": "border1 swp3.201 -> R5 e0/2.201"},
    "b": {"vrf": "tenant-b", "vip": "10.202.100.10", "snat": ["172.16.202.10", "172.16.202.11", "172.16.202.12"],
          "published": "10.10.12.37", "gw_vip": "172.16.100.17", "ai_gw": "172.16.100.21", "vni": 10002, "vip_vtep": "TMM (L3VNI 10002)", "dpu_leg": "VLAN 102", "exit": "border1 swp3.202 -> R5 e0/2.202"},
    "c": {"vrf": "tenant-c", "vip": "10.203.100.10", "snat": ["172.16.203.10", "172.16.203.11", "172.16.203.12"],
          "published": "10.10.12.38", "gw_vip": "172.16.100.18", "ai_gw": "172.16.100.22", "vni": 10003, "vip_vtep": "DPUs (L3VNI 10003)", "dpu_leg": "VLAN 103", "exit": "border1 swp3.203 -> R5 e0/2.203"},
}

PERSONA = {
    "a": {"company": "Northpeak Retail", "tool": "orders", "what": "web shop orders",
          "rows": [
              {"id": "SO-1041", "customer": "M. Novak", "items": 3, "total_eur": 184.90, "status": "shipped"},
              {"id": "SO-1042", "customer": "J. Horvat", "items": 1, "total_eur": 39.00, "status": "open"},
              {"id": "SO-1043", "customer": "A. Kovac", "items": 5, "total_eur": 412.50, "status": "open"},
              {"id": "SO-1044", "customer": "L. Babic", "items": 2, "total_eur": 77.80, "status": "returned"},
              {"id": "SO-1045", "customer": "P. Juric", "items": 4, "total_eur": 265.00, "status": "open"},
          ]},
    "b": {"company": "Harbor Bank", "tool": "payments", "what": "card payments under fraud review",
          "rows": [
              {"id": "PAY-77310", "account": "HR12-0041", "amount_eur": 9800.00, "country": "HR", "status": "flagged"},
              {"id": "PAY-77311", "account": "HR12-0077", "amount_eur": 54.20, "country": "HR", "status": "cleared"},
              {"id": "PAY-77312", "account": "HR12-0041", "amount_eur": 9750.00, "country": "PA", "status": "flagged"},
              {"id": "PAY-77313", "account": "HR12-0102", "amount_eur": 1200.00, "country": "DE", "status": "cleared"},
              {"id": "PAY-77314", "account": "HR12-0019", "amount_eur": 4999.99, "country": "SC", "status": "flagged"},
          ]},
    "c": {"company": "Driftline Logistics", "tool": "shipments", "what": "truck shipments",
          "rows": [
              {"id": "SH-5501", "route": "Zagreb -> Munich", "pallets": 18, "eta_h": 9, "status": "in_transit"},
              {"id": "SH-5502", "route": "Rijeka -> Vienna", "pallets": 22, "eta_h": 0, "status": "delivered"},
              {"id": "SH-5503", "route": "Split -> Milan", "pallets": 12, "eta_h": 14, "status": "delayed"},
              {"id": "SH-5504", "route": "Osijek -> Budapest", "pallets": 8, "eta_h": 4, "status": "in_transit"},
          ]},
}

# probe targets: every tenant's VRF VIP (tenant network) and every tenant's agent Service (cluster network)
TARGETS = {f"tenant-{t}-vip": (n["vip"], 80) for t, n in NET.items()}
TARGETS.update({f"tenant-{t}-agent": (f"agent-web.tenant-{t}.svc.cluster.local", 80) for t in NET})
TARGETS["ai-gateway"] = (NET[TENANT]["ai_gw"], 80)   # this tenant's own AI Gateway tenant

P = PERSONA[TENANT]
STATUSES = sorted({r["status"] for r in P["rows"]})
TOOLS = [
    {
        "name": P["tool"],
        "description": f"{P['company']} {P['what']}, optionally only those with one status.",
        "inputSchema": {"type": "object", "properties": {   # a string: with an array qwen2.5-1.5b stops calling the tool
            "status": {"type": "string", "enum": STATUSES, "description": "Only rows with this status"}}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "tenant_identity",
        "description": "Who this agent is and how its tenant is wired: namespace, pod, node, VRF, VIP, egress SNAT "
                       "addresses, VXLAN VNI and the fabric exit.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "egress_check",
        "description": "Call the test internet behind router R5 from this pod. The call leaves through this tenant's "
                       "own exit (TMM SNAT in the tenant VRF, DPU, border1, R5); HTTP 401 means it got there.",
        "inputSchema": {"type": "object", "properties": {}},
        "annotations": {"readOnlyHint": True},
    },
    {
        "name": "reach_test",
        "description": "Try a TCP connection from this pod to another tenant's VIP or agent, to its own, or to the "
                       "AI Gateway. Shows tenant isolation: other tenants should be unreachable.",
        "inputSchema": {"type": "object", "properties": {
            "target": {"type": "string", "enum": sorted(TARGETS), "description": "What to connect to"}},
            "required": ["target"]},
        "annotations": {"readOnlyHint": True},
    },
]


def identity():
    n = NET[TENANT]
    return {"tenant": f"tenant-{TENANT}", "company": P["company"], "namespace": os.environ.get("POD_NAMESPACE"),
            "pod": os.environ.get("POD_NAME"), "pod_ip": os.environ.get("POD_IP"), "node": os.environ.get("NODE_NAME"),
            "vrf": n["vrf"], "published_url": f"http://{n['published']}/ (BNK Gateway tenant-gw {n['gw_vip']} + L4Route in "
                                              f"{os.environ.get('POD_NAMESPACE')}, fabric VRF external, NAT on R5)",
            "tenant_network_vip": f"{n['vip']}:80 (F5VirtualServer in VRF {n['vrf']}, reachable only from tenant hosts)",
            "vip_vtep": n["vip_vtep"], "egress_snat": n["snat"],
            "egress_path": f"pod -> TMM ({n['vrf']}, SNAT) -> DPU {n['dpu_leg']} -> EVPN -> {n['exit']}",
            "ai_gateway": f"http://{n['ai_gw']}/v1, AI Gateway tenant tenant-{TENANT} (own route and VIP, reached through this "
                          f"tenant's exit), principal assistant, model qwen2.5-1.5b"}


def egress_check():
    t0 = time.time()
    try:
        urllib.request.urlopen(INTERNET, timeout=5)
        code = 200
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:
        return {"reached": False, "error": str(e)[:200], "seconds": round(time.time() - t0, 2)}
    return {"reached": code == 401, "http_status": code, "target": INTERNET, "seconds": round(time.time() - t0, 2),
            "source_seen_by_r5": f"one of {NET[TENANT]['snat']} (the TMM that took the flow)"}


def reach_test(target):
    if target not in TARGETS:
        raise ValueError(f"target must be one of {sorted(TARGETS)}")
    host, port = TARGETS[target]
    t0 = time.time()
    try:
        socket.create_connection((host, port), timeout=3).close()
        return {"target": target, "address": f"{host}:{port}", "reachable": True,
                "seconds": round(time.time() - t0, 2)}
    except OSError as e:
        return {"target": target, "address": f"{host}:{port}", "reachable": False,
                "reason": type(e).__name__ + (f": {e}" if str(e) else ""), "seconds": round(time.time() - t0, 2)}


def call_tool(name, args):
    if name == P["tool"]:
        s = args.get("status")  # models send one status or a list of them, whatever the schema says
        want = set(s) if isinstance(s, list) else {s} if s else None
        return [r for r in P["rows"] if not want or r["status"] in want]
    if name == "tenant_identity":
        return identity()
    if name == "egress_check":
        return egress_check()
    if name == "reach_test":
        return reach_test(args.get("target"))
    raise KeyError(name)


def handle(msg):
    """Return the JSON-RPC response for one message, or None for a notification."""
    mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if mid is None:
        return None
    ok = lambda result: {"jsonrpc": "2.0", "id": mid, "result": result}
    err = lambda code, text: {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": text}}
    if method == "initialize":
        want = params.get("protocolVersion")
        return ok({"protocolVersion": want if want in VERSIONS else VERSIONS[0],
                   "capabilities": {"tools": {"listChanged": False}},
                   "serverInfo": {"name": f"tenant-{TENANT}-mcp", "version": os.environ.get("APP_VERSION", "dev")}})
    if method == "ping":
        return ok({})
    if method == "tools/list":
        return ok({"tools": TOOLS})
    if method == "tools/call":
        try:
            data = call_tool(params.get("name"), params.get("arguments") or {})
        except KeyError:
            return err(-32602, f"unknown tool {params.get('name')}")
        except Exception as e:  # tool errors go back to the model, not as protocol errors
            return ok({"content": [{"type": "text", "text": f"error: {e}"}], "isError": True})
        return ok({"content": [{"type": "text", "text": json.dumps(data)}],
                   "structuredContent": {"result": data}, "isError": False})
    return err(-32601, f"method not found: {method}")


def body_size(headers):
    """Content-Length if it is an integer in 0..MAX_BODY, else None (missing counts as 0)."""
    try:
        n = int(headers.get("Content-Length") or 0)
    except ValueError:
        return None
    return n if 0 <= n <= MAX_BODY else None


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body=None, headers=None):
        self.send_response(code)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        data = json.dumps(body).encode() if body is not None else b""
        if body is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"ok": True, "tenant": TENANT})
        self._send(405, None, {"Allow": "POST"})

    def do_DELETE(self):
        self._send(200 if self.path.startswith("/mcp") else 404)

    def do_POST(self):
        if not self.path.startswith("/mcp"):
            return self._send(404, {"error": "not found"})
        size = body_size(self.headers)
        if size is None:
            return self._send(413, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "bad or oversized body"}})
        try:
            msg = json.loads(self.rfile.read(size) or b"{}")
        except ValueError:
            return self._send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
        if isinstance(msg, list):
            out = [r for r in map(handle, msg) if r]
            return self._send(200, out) if out else self._send(202)
        resp = handle(msg)
        if resp is None:
            return self._send(202)
        headers = {"Mcp-Session-Id": uuid.uuid4().hex} if msg.get("method") == "initialize" else {}
        self._send(200, resp, headers)

    def log_message(self, fmt, *args):
        if os.environ.get("MCP_LOG"):
            super().log_message(fmt, *args)


if __name__ == "__main__":
    print(f"tenant-{TENANT}-mcp ({P['company']}) on :{PORT}/mcp", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
