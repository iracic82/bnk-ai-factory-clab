#!/usr/bin/env python3
"""Rolling maintenance, one node at a time: HWE kernel 6.8 (OpenShell needs Landlock ABI v3+, Linux 6.2+)
and grow the VM disk 40G -> 100G. One stop/start per node.
Run from the EVE-NG repo:  EVENG_USERNAME=admin EVENG_PASSWORD=eve uv run --with 'paramiko<4' python 61-disk-kernel-roll.py [node ...]
"""
import asyncio, os, shlex, subprocess, sys, time
import paramiko
from eveng_mcp.config import Settings
from eveng_mcp.client import EVEClient

LAB = "/Prosimo Labs/K8s.unl"
TMP = "/opt/unetlab/tmp/0/648116c9-efda-4194-a97a-2c8f86168211"
NODES = {"bnk-w2": 8, "bnk-w1": 7, "bnk-cp1": 6}
SIZE = "100G"
SUDO = f"echo {shlex.quote(os.environ['NODE_SUDO_PASSWORD'])} | sudo -S -p '' "

def log(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)
def sh(host, cmd, t=900):
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", host, cmd], capture_output=True, text=True, timeout=t)
    return r.returncode, (r.stdout + r.stderr).strip()
def kc(args, t=900): return sh("bnk-cp1", SUDO + "env KUBECONFIG=/etc/kubernetes/admin.conf kubectl " + args, t)
def evehost(cmd):
    c = paramiko.SSHClient(); c.load_system_host_keys(); c.set_missing_host_key_policy(paramiko.RejectPolicy())
    c.connect("10.10.11.115", username="root", password=os.environ['EVE_ROOT_PASSWORD'], look_for_keys=False, allow_agent=False)
    _, o, e = c.exec_command(cmd); out = o.read().decode() + e.read().decode(); rc = o.channel.recv_exit_status(); c.close()
    return rc, out.strip()

async def status(c, nid):
    d = await c.get_node(LAB, nid); d = (d or {}).get("data", d); return d.get("status")

async def roll(c, name, nid):
    log(f"===== {name} (EVE node {nid})")
    rc, k = sh(name, "uname -r")
    rc, v = evehost(f"/opt/qemu/bin/qemu-img info {TMP}/{nid}/virtioa.qcow2 | grep 'virtual size'")
    if k.startswith("6.") and ("100 GiB" in v or "100G" in v):
        log(name, "already done:", k, v); return
    rc, o = sh(name, SUDO + "bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive "
                     "apt-get install -y -qq linux-generic-hwe-22.04 cloud-guest-utils >/dev/null && ls /boot/vmlinuz-6.8*'", 1800)
    if rc: sys.exit(f"{name}: package install failed: {o[-400:]}")
    log(name, "kernel staged:", o.splitlines()[-1])
    if name != "bnk-cp1":
        rc, o = kc(f"drain {name} --ignore-daemonsets --delete-emptydir-data --force --timeout=300s", 400)
        log(name, "drain rc", rc, o.splitlines()[-1] if o else "")
    else:
        kc(f"cordon {name}")
    sh(name, SUDO + "systemctl poweroff", 30)
    for _ in range(36):
        await asyncio.sleep(5)
        if await status(c, nid) == 0: break
    else:
        log(name, "still running after 3 min, EVE stop"); await c.stop_node(LAB, nid); await asyncio.sleep(10)
    rc, o = evehost(f"/opt/qemu/bin/qemu-img resize {TMP}/{nid}/virtioa.qcow2 {SIZE}")
    log(name, "qemu-img resize:", o)
    if rc: sys.exit(f"{name}: resize failed, node left stopped")
    await c.start_node(LAB, nid); log(name, "started")
    for _ in range(90):
        await asyncio.sleep(10)
        if sh(name, "true", 15)[0] == 0: break
    rc, o = sh(name, SUDO + "bash -c 'growpart /dev/vda 3; resize2fs /dev/vda3 >/dev/null 2>&1; uname -r; df -h / | tail -1'")
    log(name, "after boot:", " | ".join(o.splitlines()[-2:]))
    rc, o = kc(f"wait --for=condition=Ready node/{name} --timeout=600s", 660); log(name, o[-40:])
    kc(f"uncordon {name}")
    await asyncio.sleep(90)
    rc, o = kc("get pods -A -o wide --no-headers | grep -E 'f5-tmm|NotReady|CrashLoop' | awk '{print $2,$4,$8}'")
    log(name, "tmm:", o.replace("\n", " ; "))

async def main():
    c = EVEClient(Settings()); await c.open(); await c.login()
    for name in (sys.argv[1:] or list(NODES)):
        await roll(c, name, NODES[name])
    await c.close()
    print(kc("get nodes -o wide --no-headers")[1])

asyncio.run(main())
