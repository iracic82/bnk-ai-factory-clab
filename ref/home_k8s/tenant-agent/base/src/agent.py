"""Tenant agent: one tenant's assistant in its own namespace, LLM behind F5 AI Gateway, tools from the tenant's MCP server.

Same loop as apps/agentic-app: list the MCP tools, offer them to the model, run each tool call through MCP, stop
when the model answers in text. The page also runs the network tools directly (no model) for a fast isolation demo.
Stdlib only.
"""
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AIGW = os.environ.get("AIGW_URL", "http://10.10.12.33/v1").rstrip("/")
KEY = os.environ.get("AIGW_KEY", "").strip()
MODEL = os.environ.get("MODEL", "qwen2.5-1.5b")
MCP = os.environ.get("MCP_URL", "http://127.0.0.1:8001/mcp")
TENANT = os.environ.get("TENANT", "a")
VERSION = os.environ.get("APP_VERSION", "dev")
PORT = int(os.environ.get("PORT", "8080"))
MAX_STEPS = 4
MAX_BODY = 16384
LOOK = {  # company, accent colour, example question for the business tool
    "a": ("Northpeak Retail", "#0b6bcb", "Which orders are still open and what are they worth together?"),
    "b": ("Harbor Bank", "#a3367a", "Which payments are flagged for fraud review?"),
    "c": ("Driftline Logistics", "#b35c00", "Which shipments are delayed or still in transit?"),
}
COMPANY, ACCENT, EXAMPLE = LOOK[TENANT]
SYSTEM = (f"You are the assistant of {COMPANY}, tenant tenant-{TENANT} of a shared AI factory that runs F5 BIG-IP Next "
          "for Kubernetes. Use the tools to get live data before answering. For questions about the network, "
          "isolation or other tenants use tenant_identity, egress_check and reach_test. Answer briefly.")
DIRECT = {"tenant_identity", "egress_check", "reach_test"}  # tools the page may call without the model


def post(url, body, headers=None, timeout=30):
    req = urllib.request.Request(url, json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Accept": "application/json, text/event-stream", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.headers, json.loads(r.read() or b"null")


class McpClient:
    def __init__(self, url):
        self.url, self.session, self.n = url, None, 0

    def rpc(self, method, params=None):
        self.n += 1
        h = {"Mcp-Session-Id": self.session} if self.session else {}
        hdrs, resp = post(self.url, {"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}, h)
        self.session = self.session or hdrs.get("Mcp-Session-Id")
        if "error" in resp:
            raise RuntimeError(resp["error"]["message"])
        return resp["result"]

    def connect(self):
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                "clientInfo": {"name": f"tenant-{TENANT}-agent", "version": VERSION}})
        post(self.url, {"jsonrpc": "2.0", "method": "notifications/initialized"},
             {"Mcp-Session-Id": self.session} if self.session else {})
        return self.rpc("tools/list")["tools"]

    def call(self, name, args):
        res = self.rpc("tools/call", {"name": name, "arguments": args})
        return "".join(p.get("text", "") for p in res.get("content", []))


def tool(name, args):
    if name not in DIRECT:
        raise ValueError("not a direct tool")
    mcp = McpClient(MCP)
    mcp.connect()
    return json.loads(mcp.call(name, args))


def ask(question):
    trace, t0 = [], time.time()
    mcp = McpClient(MCP)
    tools = [{"type": "function", "function": {"name": t["name"], "description": t["description"],
                                               "parameters": t["inputSchema"]}} for t in mcp.connect()]
    msgs = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": question}]
    for _ in range(MAX_STEPS):
        _, out = post(AIGW + "/chat/completions", {"model": MODEL, "messages": msgs, "tools": tools,
                                                   "temperature": 0.1, "max_tokens": 400},
                      {"Authorization": f"Bearer {KEY}"}, timeout=240)
        if "choices" not in out:
            raise RuntimeError(f"AI Gateway: {json.dumps(out)[:300]}")
        msg = out["choices"][0]["message"]
        calls = msg.get("tool_calls") or []
        if not calls:
            return {"answer": msg.get("content", ""), "trace": trace, "model": out.get("model", MODEL),
                    "seconds": round(time.time() - t0, 1)}
        msgs.append({"role": "assistant", "content": msg.get("content") or "", "tool_calls": calls})
        for c in calls:
            fn = c["function"]
            args = json.loads(fn.get("arguments") or "{}") if isinstance(fn.get("arguments"), str) else fn.get("arguments") or {}
            text = mcp.call(fn["name"], args)
            trace.append({"tool": fn["name"], "args": args, "result": text[:600]})
            msgs.append({"role": "tool", "tool_call_id": c.get("id", fn["name"]), "content": text})
    return {"answer": "(stopped after %d tool rounds)" % MAX_STEPS, "trace": trace, "model": MODEL,
            "seconds": round(time.time() - t0, 1)}


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>%(company)s Agent</title><style>
:root{--bg:#f6f7f9;--fg:#15181d;--card:#fff;--line:#d9dde3;--acc:%(acc)s;--mut:#5d6672;--ok:#0b7a3e;--no:#b42318}
@media (prefers-color-scheme:dark){:root{--bg:#111418;--fg:#e7eaee;--card:#1a1e24;--line:#2c323b;--mut:#9aa4b0;
--ok:#4cc38a;--no:#ff6b5e}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
main{max-width:820px;margin:0 auto;padding:16px}h1{margin:0;font-size:22px}h2{font-size:15px;margin:0 0 6px}
.bar{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.tag{background:var(--acc);color:#fff;border-radius:4px;padding:2px 8px;font-size:13px}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin-top:12px}
.grid{display:grid;grid-template-columns:max-content 1fr;gap:2px 12px;font-size:13px}.grid b{color:var(--mut);font-weight:500}
.btns{display:flex;flex-wrap:wrap;gap:6px}.btns button{background:transparent;color:var(--fg);border:1px solid var(--line);
font-size:13px;padding:6px 10px}.ok{color:var(--ok)}.no{color:var(--no)}
form{display:flex;gap:8px;margin-top:8px}input{flex:1;min-width:0;padding:10px;border:1px solid var(--line);
border-radius:6px;background:var(--card);color:var(--fg)}button{padding:10px 16px;border:0;border-radius:6px;
background:var(--acc);color:#fff;cursor:pointer}pre{white-space:pre-wrap;word-break:break-word;font-size:12px;
color:var(--mut);margin:4px 0 0}.q{color:var(--mut);font-size:13px;cursor:pointer;text-decoration:underline}
</style></head><body><main>
<div class="bar"><h1>%(company)s</h1><span class="tag">tenant-%(t)s</span>
<span style="color:var(--mut);font-size:13px">model %(model)s via F5 AI Gateway &middot; tools via MCP &middot; %(ver)s</span></div>
<div class="card"><h2>Where this agent runs</h2><div class="grid" id="who">loading...</div></div>
<div class="card"><h2>Isolation check (tools run directly, no model)</h2><div class="btns" id="btns"></div>
<div id="res" style="font-size:13px;margin-top:8px"></div></div>
<div class="card"><h2>Ask the agent</h2>
<span class="q">%(example)s</span> &middot; <span class="q">Can you reach the other tenants' agents?</span> &middot;
<span class="q">How does my traffic leave the factory?</span>
<form id="f"><input id="i" placeholder="Ask %(company)s's agent" autocomplete="off"><button>Ask</button></form>
<div id="out"></div></div></main><script>
const T='%(t)s',out=document.getElementById('out'),i=document.getElementById('i'),res=document.getElementById('res');
function esc(s){return String(s).replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
async function tool(name,args){const r=await fetch('api/tool',{method:'POST',headers:{'Content-Type':'application/json'},
body:JSON.stringify({name:name,arguments:args||{}})});const d=await r.json();if(d.error)throw new Error(d.error);return d}
tool('tenant_identity').then(d=>{document.getElementById('who').innerHTML=Object.entries(d).map(([k,v])=>
'<b>'+esc(k)+'</b><span>'+esc(Array.isArray(v)?v.join(', '):v)+'</span>').join('')}).catch(e=>{
document.getElementById('who').textContent='error: '+e.message});
const checks=['a','b','c'].flatMap(x=>['tenant-'+x+'-agent','tenant-'+x+'-vip']).concat(['ai-gateway']);
const B=document.getElementById('btns');
function line(html){const p=document.createElement('div');p.innerHTML=html;res.prepend(p)}
checks.forEach(c=>{const b=document.createElement('button');b.textContent=c+(c.startsWith('tenant-'+T)?' (own)':'');
b.onclick=async()=>{try{const d=await tool('reach_test',{target:c});line('<span class="'+(d.reachable?'ok">reachable':'no">blocked')+
'</span> '+esc(c)+' '+esc(d.address)+' ('+d.seconds+' s'+(d.reason?', '+esc(d.reason):'')+')')}catch(e){line('error: '+esc(e.message))}};
B.appendChild(b)});
const eb=document.createElement('button');eb.textContent='egress to internet';B.appendChild(eb);
eb.onclick=async()=>{try{const d=await tool('egress_check');line('<span class="'+(d.reached?'ok">reached':'no">failed')+
'</span> R5 test internet, HTTP '+esc(d.http_status||'-')+', source '+esc(d.source_seen_by_r5||d.error))}catch(e){line('error: '+esc(e.message))}};
document.querySelectorAll('.q').forEach(e=>e.onclick=()=>{i.value=e.textContent;go()});
document.getElementById('f').onsubmit=e=>{e.preventDefault();go()};
async function go(){const q=i.value.trim();if(!q)return;const c=document.createElement('div');c.className='card';
c.innerHTML='<b>'+esc(q)+'</b><pre>thinking (CPU model, can take a minute)...</pre>';out.prepend(c);
try{const r=await fetch('api/ask',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({question:q})});
const d=await r.json();if(d.error)throw new Error(d.error);
c.innerHTML='<b>'+esc(q)+'</b><p>'+esc(d.answer)+'</p>'+d.trace.map(t=>'<pre>tool '+esc(t.tool)+' '+esc(JSON.stringify(t.args))+
' -> '+esc(t.result)+'</pre>').join('')+'<pre>'+d.seconds+' s, '+esc(d.model)+'</pre>'}
catch(err){c.querySelector('pre').textContent='error: '+err.message}}
</script></body></html>"""


def body_size(headers):
    """Content-Length if it is an integer in 0..MAX_BODY, else None (missing counts as 0)."""
    try:
        n = int(headers.get("Content-Length") or 0)
    except ValueError:
        return None
    return n if 0 <= n <= MAX_BODY else None


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"ok": True, "tenant": TENANT, "version": VERSION})
        if self.path in ("/", "/index.html"):
            return self._send(200, PAGE % {"company": COMPANY, "acc": ACCENT, "t": TENANT, "model": MODEL,
                                           "ver": VERSION, "example": EXAMPLE}, "text/html; charset=utf-8")
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path not in ("/api/ask", "/api/tool"):
            return self._send(404, {"error": "not found"})
        size = body_size(self.headers)
        if size is None:
            return self._send(413, {"error": "bad or oversized body"})
        try:
            req = json.loads(self.rfile.read(size))
            if self.path == "/api/tool":
                return self._send(200, tool(req["name"], req.get("arguments") or {}))
            self._send(200, ask(req["question"][:500]))
        except Exception as e:
            msg = str(e).replace(KEY, "***") if KEY else str(e)  # never echo the virtual key
            self._send(502, {"error": msg[:400]})


if __name__ == "__main__":
    print(f"tenant-{TENANT} agent ({COMPANY}) {VERSION} on :{PORT}, AI Gateway {AIGW}, model {MODEL}, MCP {MCP}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
