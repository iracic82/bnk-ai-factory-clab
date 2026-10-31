"""Tests: run the tenant MCP server for each persona and speak MCP to it; the agent's /api/tool refuses model-only tools."""
import json
import os
import subprocess
import sys
import time
import unittest
import urllib.error
import urllib.request

SRC = os.path.join(os.path.dirname(__file__), "..", "base", "src")


def post(url, body):
    req = urllib.request.Request(url, json.dumps(body).encode(), headers={"Content-Type": "application/json"},
                                 method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def wait(url):
    for _ in range(50):
        try:
            urllib.request.urlopen(url, timeout=1)
            return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"{url} did not come up")


class TenantMcpTest(unittest.TestCase):
    def run_server(self, tenant, port):
        p = subprocess.Popen([sys.executable, os.path.join(SRC, "mcp_server.py")],
                             env={**os.environ, "TENANT": tenant, "MCP_PORT": str(port), "POD_NAMESPACE": f"tenant-{tenant}"},
                             stdout=subprocess.DEVNULL)
        self.addCleanup(p.terminate)
        wait(f"http://127.0.0.1:{port}/healthz")
        return f"http://127.0.0.1:{port}/mcp"

    def call(self, url, name, args=None):
        res = post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": name, "arguments": args or {}}})
        return res["result"]

    def test_personas(self):
        for i, (t, tool, status) in enumerate([("a", "orders", "open"), ("b", "payments", "flagged"),
                                               ("c", "shipments", "delayed")]):
            url = self.run_server(t, 18101 + i)
            names = [x["name"] for x in post(url, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]]
            self.assertEqual(names, [tool, "tenant_identity", "egress_check", "reach_test"])
            rows = self.call(url, tool, {"status": status})["structuredContent"]["result"]
            self.assertTrue(rows and all(r["status"] == status for r in rows))
            if t == "c":  # "delayed or in transit": the models send a list
                rows = self.call(url, tool, {"status": ["delayed", "in_transit"]})["structuredContent"]["result"]
                self.assertEqual(sorted(r["id"] for r in rows), ["SH-5501", "SH-5503", "SH-5504"])
            who =self.call(url, "tenant_identity")["structuredContent"]["result"]
            self.assertEqual((who["tenant"], who["vrf"], who["namespace"]), (f"tenant-{t}", f"tenant-{t}", f"tenant-{t}"))

    def test_reach_test_only_known_targets(self):
        url = self.run_server("a", 18110)
        bad = self.call(url, "reach_test", {"target": "http://169.254.169.254/"})
        self.assertTrue(bad["isError"])
        ok = self.call(url, "reach_test", {"target": "tenant-b-vip"})
        self.assertFalse(ok["isError"])
        self.assertIn("reachable", ok["structuredContent"]["result"])

    def test_agent_direct_tools(self):
        mcp = self.run_server("c", 18111)
        p = subprocess.Popen([sys.executable, os.path.join(SRC, "agent.py")],
                             env={**os.environ, "TENANT": "c", "PORT": "18112", "MCP_URL": mcp}, stdout=subprocess.DEVNULL)
        self.addCleanup(p.terminate)
        wait("http://127.0.0.1:18112/healthz")
        page = urllib.request.urlopen("http://127.0.0.1:18112/").read().decode()
        self.assertIn("Driftline Logistics", page)
        who = post("http://127.0.0.1:18112/api/tool", {"name": "tenant_identity"})
        self.assertEqual(who["company"], "Driftline Logistics")
        with self.assertRaises(urllib.error.HTTPError) as e:  # business data only goes through the model
            post("http://127.0.0.1:18112/api/tool", {"name": "shipments"})
        self.assertEqual(e.exception.code, 502)


if __name__ == "__main__":
    unittest.main()
