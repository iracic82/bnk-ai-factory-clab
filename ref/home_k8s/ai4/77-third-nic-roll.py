#!/usr/bin/env python3
"""Rolling maintenance, one TMM node at a time: add a 3rd NIC (EVE e2 -> ens5) on the node network
(EVE network 1, "Mgmt 10.10.12.0/24"). ens5 carries no host IP; it is the parent of TMM's macvlan
"internal" leg (self IPs 10.10.12.41-43), the target of the CSRC egress VXLAN tunnels.
Why a separate NIC and not macvlan on ens3: a macvlan child cannot talk to its parent's own IP, and
CSRC pins the tunnel to 'local <node IP> dev ens3', so the local node could not reach its own TMM.
Run from the EVE-NG repo:  EVENG_USERNAME=admin EVENG_PASSWORD=... NODE_SUDO_PASSWORD=... uv run python 77-third-nic-roll.py [node ...]
"""
import asyncio, os, shlex, subprocess, sys, time
from eveng_mcp.config import Settings
from eveng_mcp.client import EVEClient

LAB = "/Prosimo Labs/K8s.unl"
NODES = {"bnk-w1": 7, "bnk-w2": 8}
MGMT_NET = "1"
SUDO = f"echo {shlex.quote(os.environ['NODE_SUDO_PASSWORD'])} | sudo -S -p '' "

def log(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)
def sh(host, cmd, t=900):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", host, cmd], capture_output=True, text=True, timeout=t)
    return r.returncode, (r.stdout + r.stderr).strip()
def kc(args, t=900): return sh("bnk-cp1", SUDO + "env KUBECONFIG=/etc/kubernetes/admin.conf kubectl " + args, t)

async def node(c, nid):
    d = await c.get_node(LAB, nid); return (d or {}).get("data", d)

async def roll(c, name, nid):
    log(f"===== {name} (EVE node {nid})")
    if (await node(c, nid)).get("ethernet") == 3 and sh(name, "ip link show ens5")[0] == 0:
        log(name, "already has ens5"); return
    # No-IP profile first, so NetworkManager never DHCPs the new NIC onto the node network.
    rc, o = sh(name, SUDO + "bash -c 'nmcli -t -f NAME con show | grep -qx tmm-internal || nmcli con add type ethernet "
               "ifname ens5 con-name tmm-internal ipv4.method disabled ipv6.method disabled connection.autoconnect yes'")
    log(name, "nm profile rc", rc, o[-120:])
    rc, o = kc(f"drain {name} --ignore-daemonsets --delete-emptydir-data --force --timeout=300s", 400)
    log(name, "drain rc", rc, o.splitlines()[-1] if o else "")
    booted = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    sh(name, SUDO + "systemctl poweroff", 30)
    for _ in range(36):
        await asyncio.sleep(5)
        if (await node(c, nid)).get("status") == 0: break
    else:
        log(name, "still running after 3 min, EVE stop"); await c.stop_node(LAB, nid); await asyncio.sleep(10)
    await c.edit_node(LAB, nid, ethernet=3)
    await c.connect_interface(LAB, nid, {"2": MGMT_NET})
    i = await c.get_interfaces(LAB, nid); i = (i or {}).get("data", i)
    log(name, "interfaces:", i.get("ethernet"))
    await c.start_node(LAB, nid); log(name, "started")
    for _ in range(90):
        await asyncio.sleep(10)
        if sh(name, "true", 15)[0] == 0: break
    log(name, "links:", sh(name, "ip -br addr | grep -E '^ens'")[1].replace("\n", " ; "))
    rc, o = kc(f"wait --for=condition=Ready node/{name} --timeout=600s", 660); log(name, o[-40:])
    kc(f"uncordon {name}")
    # The Ready condition can still be stale from before the reboot: wait for a ready TMM pod started after it.
    sel = f"get pods -l app=f5-tmm --field-selector spec.nodeName={name} -o jsonpath="
    for _ in range(90):
        await asyncio.sleep(10)
        rc, o = kc(sel + "'{.items[0].status.startTime} {.items[0].status.containerStatuses[*].ready}'")
        f = o.split()
        if f and f[0] > booted and "false" not in f[1:] and len(f) > 1: break
    log(name, "tmm:", o)

async def main():
    c = EVEClient(Settings()); await c.open(); await c.login()
    for name in (sys.argv[1:] or list(NODES)):
        await roll(c, name, NODES[name])
    await c.close()
    print(kc("get nodes -o wide --no-headers")[1])

asyncio.run(main())
