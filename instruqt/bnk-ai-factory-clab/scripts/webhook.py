#!/usr/bin/env python3
"""The team webhook outside the factory, on the client behind r5 (chapters 10 to 13).

One line per request in the log, then the body, then a blank line:

    2026-11-01T12:00:00Z POST /report from=10.203.200.10 len=312
    MRN 00412233,M. Novak,cardiology,1840.00
    ...

`from=` is the address the client saw, which is a tenant's SNAT address when the request left through BNK. The
reply is always a 200 with the body "ok". install/35-bnk-network.sh starts it at track start and sends one
GET /probe through Cobalt's egress; the chapters count "POST /report".

Replaces a socat one-liner: socat strips the backslashes of its SYSTEM: address, so the printf there wrote a
response without CRLFs that no HTTP client accepted ("error getting response", play 5, 2026-11-01).
"""
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1] if len(sys.argv) > 1 else "/tmp/webhook.log"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080


class Hook(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _record(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(LOG, "a") as f:
            f.write(f"{stamp} {self.command} {self.path} from={self.client_address[0]} len={len(body)}\n")
            if body:
                f.write(body.decode("utf-8", "replace").rstrip("\n") + "\n")
            f.write("\n")
        out = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    do_POST = _record
    do_GET = _record
    do_PUT = _record

    def log_message(self, *args):
        return


if __name__ == "__main__":
    open(LOG, "a").close()
    ThreadingHTTPServer(("0.0.0.0", PORT), Hook).serve_forever()
