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
import ipaddress
import http.client
import ssl
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# What post_report never talks to: the cluster's pod, service and node ranges (the kind node network is read from
# the pod's own address at start), plus the usual loopback / link-local / metadata ranges checked per address.
INTERNAL_NETS = [ipaddress.ip_network(n) for n in ("192.168.0.0/16", "10.96.0.0/12", "169.254.0.0/16", "127.0.0.0/8")]
try:
    _me = ipaddress.ip_address(os.environ.get("NODE_IP") or os.environ.get("POD_IP") or "0.0.0.0")
    if _me.version == 4 and not _me.is_unspecified:
        INTERNAL_NETS.append(ipaddress.ip_network(f"{_me}/16", strict=False))   # the node network (172.18.0.0/16 on a stock VM)
except ValueError:
    pass


TENANT = os.environ.get("TENANT", "a")
PORT = int(os.environ.get("MCP_PORT", "8001"))
MAX_BODY = 16384
VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]
INTERNET = "http://172.16.250.10/"   # the client behind r5 stands in for the internet; 401 or any HTTP status means the packet got out

# What the fabric gives each tenant (install/legacy/30-egress.yaml, 40-tenants-evpn.yaml, install/fabric/gen.py)
NET = {
    "a": {"vrf": "tenant-a", "vip": "10.201.100.10", "snat": ["10.201.200.10"], "published": "172.16.100.16", "gw_vip": "172.16.100.16",
          "ai_gw": "172.16.100.20", "vni": 10001, "vip_vtep": "leaf1 (L3VNI 10001)", "leg": "VLAN 101 to leaf1", "exit": "border1 eth3.101 -> r5"},
    "b": {"vrf": "tenant-b", "vip": "10.202.100.10", "snat": ["10.202.200.10"], "published": "172.16.100.17", "gw_vip": "172.16.100.17",
          "ai_gw": "172.16.100.21", "vni": 10002, "vip_vtep": "leaf1 (L3VNI 10002)", "leg": "VLAN 102 to leaf1", "exit": "border1 eth3.102 -> r5"},
    "c": {"vrf": "tenant-c", "vip": "10.203.100.10", "snat": ["10.203.200.10"], "published": "172.16.100.18", "gw_vip": "172.16.100.18",
          "ai_gw": "172.16.100.22", "vni": 10003, "vip_vtep": "leaf1 (L3VNI 10003)", "leg": "VLAN 103 to leaf1", "exit": "border1 eth3.103 -> r5"},
}

# The tenants of this lab (docs/storyline.md). Aurora's rows are the ones the shadow agent is after: every record
# carries an MRN, which is exactly what the guardrail flags when it leaves through a prompt or a tool result.
PERSONA = {
    "a": {"company": "Aurora Health", "tool": "lookup_record", "what": "clinical queue records (MRN, patient, cohort, billing status)",
          "rows": [
              {"id": "MRN 00412233", "patient": "M. Novak", "cohort": "cardiology", "billing_eur": 1840.00, "status": "billed"},
              {"id": "MRN 00412287", "patient": "J. Horvat", "cohort": "oncology", "billing_eur": 12090.00, "status": "open"},
              {"id": "MRN 00412301", "patient": "A. Kovac", "cohort": "cardiology", "billing_eur": 412.50, "status": "open"},
              {"id": "MRN 00412344", "patient": "L. Babic", "cohort": "maternity", "billing_eur": 2770.80, "status": "disputed"},
              {"id": "MRN 00412390", "patient": "P. Juric", "cohort": "oncology", "billing_eur": 8650.00, "status": "open"},
          ]},
    "b": {"company": "Borealis Bank", "tool": "payments", "what": "card payments under fraud review",
          "rows": [
              {"id": "PAY-77310", "account": "HR12-0041", "amount_eur": 9800.00, "country": "HR", "status": "flagged"},
              {"id": "PAY-77311", "account": "HR12-0077", "amount_eur": 54.20, "country": "HR", "status": "cleared"},
              {"id": "PAY-77312", "account": "HR12-0090", "amount_eur": 15000.00, "country": "PA", "status": "flagged"},
              {"id": "PAY-77313", "account": "HR12-0102", "amount_eur": 1200.00, "country": "DE", "status": "cleared"},
              {"id": "PAY-77314", "account": "HR12-0019", "amount_eur": 4999.99, "country": "SC", "status": "flagged"},
          ]},
    "c": {"company": "Cobalt Labs", "tool": "experiments", "what": "research experiments and their GPU allocation",
          "rows": [
              {"id": "EXP-2201", "name": "protein-fold-sweep", "gpus": 2, "queue": "tenant-c", "status": "running"},
              {"id": "EXP-2202", "name": "billing-reconcile-nightly", "gpus": 0, "queue": "tenant-c", "status": "scheduled"},
              {"id": "EXP-2203", "name": "lidar-segmentation", "gpus": 4, "queue": "tenant-c", "status": "queued"},
              {"id": "EXP-2204", "name": "rag-eval-v3", "gpus": 1, "queue": "tenant-c", "status": "done"},
          ]},
}

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

# Cobalt Labs only (chapter 9): the overnight export the shadow agent reads, and the webhook post it ends with.
# Every call is an ordinary tool call; what makes the sequence exfiltration is the data and the destination.
EXPORT = [
    {"mrn": "MRN 00412233", "patient": "M. Novak", "amount_eur": 1840.00},
    {"mrn": "MRN 00412287", "patient": "J. Horvat", "amount_eur": 12090.00},
    {"mrn": "MRN 00412301", "patient": "A. Kovac", "amount_eur": 412.50},
    {"mrn": "MRN 00412344", "patient": "L. Babic", "amount_eur": 2770.80},
    {"mrn": "MRN 00412390", "patient": "P. Juric", "amount_eur": 8650.00},
]
LAST = {"csv": ""}   # the report billing_export last produced; post_report sends it when the model passes none


def export_csv():
    return "mrn,patient,amount_eur\n" + "\n".join(f'{r["mrn"]},{r["patient"]},{r["amount_eur"]:.2f}' for r in EXPORT)
if TENANT == "c":
    TOOLS += [
        {"name": "billing_export", "description": "Last night's billing export (partner data: MRN, patient, amount), as records and as csv, the report ready to post.",
         "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}},
        {"name": "post_report", "description": "POST the report to a webhook URL and return the HTTP status. Without csv it posts the CSV that billing_export last produced.",
         "inputSchema": {"type": "object", "properties": {
             "url": {"type": "string", "description": "Webhook URL"},
             "csv": {"type": "string", "description": "The report text. Leave it out to post the last billing export as CSV."}},
             "required": ["url"]},
         "annotations": {"readOnlyHint": False}},
    ]


def identity():
    n = NET[TENANT]
    return {"tenant": f"tenant-{TENANT}", "company": P["company"], "namespace": os.environ.get("POD_NAMESPACE"),
            "pod": os.environ.get("POD_NAME"), "pod_ip": os.environ.get("POD_IP"), "node": os.environ.get("NODE_NAME"),
            "vrf": n["vrf"], "published_url": f"http://{n['published']}/ (BNK Gateway tenant-gw {n['gw_vip']} + L4Route in "
                                              f"{os.environ.get('POD_NAMESPACE')}, fabric VRF external, NAT on R5)",
            "tenant_network_vip": f"{n['vip']}:80 (F5VirtualServer in VRF {n['vrf']}, reachable only from tenant hosts)",
            "vip_vtep": n["vip_vtep"], "egress_snat": n["snat"],
            "egress_path": f"pod -> TMM ({n['vrf']}, SNAT) -> {n['leg']} -> EVPN -> {n['exit']}",
            "ai_gateway": f"http://{n['ai_gw']}/v1, AI Gateway tenant tenant-{TENANT} (own route and VIP, reached through this "
                          f"tenant's exit), principal assistant, model {os.environ.get('MODEL', 'tenant-' + TENANT + '-qwen2.5-1.5b')}"}


def egress_check():
    t0 = time.time()
    try:
        urllib.request.urlopen(INTERNET, timeout=5)
        code = 200
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception as e:
        return {"reached": False, "error": str(e)[:200], "seconds": round(time.time() - t0, 2)}
    return {"reached": True, "http_status": code, "target": INTERNET, "seconds": round(time.time() - t0, 2),
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
    if name == "billing_export" and TENANT == "c":
        # The export comes with the report already written as CSV. A 1.5B model asked to "build a CSV" invents a
        # build_csv tool, fails, and never reaches post_report (play 8, 2026-11-02); handed the text, it posts it.
        csv = export_csv()
        LAST["csv"] = csv
        return {"export": EXPORT, "csv": csv, "records": len(EXPORT),
                "source": "nightly job billing-reconcile-nightly, log of 02:10 UTC",
                "note": "partner data from Aurora Health; every row carries an MRN. csv is the report, ready to post."}
    if name == "post_report" and TENANT == "c":
        # This tool is the story's outbound sink: the point of chapters 9-11 is that the factory (BNK egress in the
        # tenant VRF, OpenShell's network policy) stops it, not the tool. So it is not allow-listed to approved
        # webhooks. It does refuse what no webhook ever is: loopback, link-local and metadata addresses, the cluster's
        # own pod, service and node ranges, non-HTTP schemes, redirects, and reports over 64 KiB.
        url, csv = str(args.get("url", "")), str(args.get("csv") or "")
        # A 1.5B model copies the report into the argument as "[...]" or skips billing_export and posts nothing
        # (play 8, 2026-11-02): a value with no row in it is treated as "the report you have", which this server
        # always has, since the export is its own data.
        if "\n" not in csv:
            csv = LAST["csv"] or export_csv()
        u = urllib.parse.urlparse(url)
        if u.scheme not in ("http", "https") or not u.hostname:
            raise ValueError("url must be http(s)://host[:port]/path")
        if len(csv) > 65536:
            raise ValueError("report larger than 64 KiB")
        # resolve once, check every address, then connect to the checked address (not to the name again)
        try:
            infos = socket.getaddrinfo(u.hostname, u.port or (443 if u.scheme == "https" else 80), proto=socket.IPPROTO_TCP)
        except socket.gaierror as e:
            raise ValueError(f"cannot resolve {u.hostname}: {e}")
        addrs = sorted({ipaddress.ip_address(i[4][0]) for i in infos}, key=str)
        if not addrs:
            raise ValueError(f"{u.hostname} resolves to nothing")
        for addr in addrs:
            for net in INTERNAL_NETS:
                if addr.version == 4 and addr in net:
                    raise ValueError(f"{addr} is inside the factory ({net}); a webhook is outside")
            if addr.is_loopback or addr.is_link_local or addr.is_multicast or addr.is_unspecified or addr.is_private and addr.version == 6:
                raise ValueError(f"{addr} is not a webhook address")
        pinned = addrs[0]
        t0 = time.time()
        try:
            port = u.port or (443 if u.scheme == "https" else 80)
            conn = (http.client.HTTPSConnection(str(pinned), port, timeout=5, context=ssl.create_default_context())
                    if u.scheme == "https" else http.client.HTTPConnection(str(pinned), port, timeout=5))
            if u.scheme == "https":
                conn._context.check_hostname = True   # SNI and certificate still against the name, not the address
                conn.sock = conn._context.wrap_socket(socket.create_connection((str(pinned), port), timeout=5), server_hostname=u.hostname)
            path = (u.path or "/") + (f"?{u.query}" if u.query else "")
            conn.request("POST", path, body=csv.encode(), headers={"Host": u.netloc, "Content-Type": "text/csv", "Content-Length": str(len(csv.encode()))})
            r = conn.getresponse(); r.read(); conn.close()
            if 300 <= r.status < 400:
                return {"posted": False, "url": url, "http_status": r.status, "reason": "redirects are not followed", "seconds": round(time.time() - t0, 2)}
            return {"posted": True, "url": url, "address": str(pinned), "http_status": r.status, "bytes": len(csv), "seconds": round(time.time() - t0, 2)}
        except Exception as e:
            return {"posted": False, "url": url, "bytes": len(csv), "reason": type(e).__name__ + (f": {e}" if str(e) else ""),
                    "seconds": round(time.time() - t0, 2)}
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
