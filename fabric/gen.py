#!/usr/bin/env python3
"""Writes fabric/nodes/<name>/{daemons,frr.conf,setup.sh} for every row in nodes.csv.

Same design as the EVE fabric (Home_k8s/install/fabric): eBGP unnumbered underlay on loopbacks, EVPN on the same
sessions, symmetric IRB with one L3VNI per VRF, route targets under one shared ASN because every leaf has its own.
Interfaces are containerlab's eth1.. instead of swp1.., and what the EVE lab did on the stand-in DPUs the leaves do
here: the leaf is TMM's gateway (172.16.10.1, AS 65000) and TMM's eBGP peer in every tenant VRF.

Ports, fixed by clab/bnk-factory.clab.yml:
  spine   eth1 leaf1, eth2 leaf2, eth3 border1
  leaf    eth1 spine1, eth2 spine2, eth3 handoff to a kind worker (untagged = VRF external, 101-103 = tenants)
  border  eth1 spine1, eth2 spine2, eth3 to r5 (VRF-lite: eth3.200 external, eth3.101-103 tenants)
  r5      eth1 to border1 (same subinterfaces), eth2 to the client

Run: python3 fabric/gen.py
"""
import csv, os, stat

HERE = os.path.dirname(os.path.abspath(__file__))
RT_ASN = 65000                 # shared route-target ASN
TMM_ASN = 65100                # what TMM speaks (GlobalRoutingConfig)
TMM_GW_ASN = 65000             # what TMM expects its gateway at 172.16.10.1 to be
R5_ASN = 65500
# vrf, table, l3vni, leaf handoff subnet (leaf .1, TMM .11), VIP pool TMM announces, border<->r5 /30
VRFS = [
    ("external", 1000, 10000, "172.16.10.0/24", "172.16.100.0/24", "172.16.200"),
    ("tenant-a", 1001, 10001, "172.17.101.0/24", "10.201.100.0/24", "172.16.201"),
    ("tenant-b", 1002, 10002, "172.17.102.0/24", "10.202.100.0/24", "172.16.202"),
    ("tenant-c", 1003, 10003, "172.17.103.0/24", "10.203.100.0/24", "172.16.203"),
]
# the tenant SNAT pools TMM also announces in each VRF (manifests/bnk/30-egress.yaml): accepted from TMM, passed to r5
SNAT = {"tenant-a": "10.201.200.0/24", "tenant-b": "10.202.200.0/24", "tenant-c": "10.203.200.0/24"}
VLAN = {"external": 200, "tenant-a": 101, "tenant-b": 102, "tenant-c": 103}
UPLINKS = {"spine": 3, "leaf": 2, "border": 2}

DAEMONS = """bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=yes
fabricd=no
vrrpd=no
pathd=no
staticd=yes
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
staticd_options="-A 127.0.0.1"
bfdd_options="   -A 127.0.0.1"
"""


def gw(subnet, host):            # "172.16.10.0/24", 1 -> "172.16.10.1/24"
    net, plen = subnet.split("/")
    return ".".join(net.split(".")[:3] + [str(host)]) + "/" + plen


def vrf_vni_map():
    # zebra's VRF -> L3VNI mapping; without it bgpd has no VNI to put behind "advertise ipv4 unicast" and exports
    # no type-5 routes at all
    c = []
    for vrf, table, vni, *_ in VRFS:
        c += [f"vrf {vrf}", f" vni {vni}", "exit-vrf", "!"]
    return c


def underlay(name, asn, lo, nports, vrfs=False):
    c = [f"frr defaults datacenter", f"hostname {name}", "service integrated-vtysh-config", "!"]
    c += vrf_vni_map() if vrfs else []
    c += [f"router bgp {asn}", f" bgp router-id {lo}", " no bgp ebgp-requires-policy", " no bgp default ipv4-unicast",
         " bgp bestpath as-path multipath-relax", " neighbor fabric peer-group", " neighbor fabric remote-as external",
         " neighbor fabric capability extended-nexthop", " neighbor fabric bfd"]
    c += [f" neighbor eth{i} interface peer-group fabric" for i in range(1, nports + 1)]
    c += [" !", " address-family ipv4 unicast", f"  network {lo}/32", "  neighbor fabric activate", " exit-address-family",
          " !", " address-family l2vpn evpn", "  neighbor fabric activate"]
    return c


def vrf_bgp(asn, lo, vrf, vni, extra):
    # "advertise ipv4 unicast" exports the VRF's BGP table as type-5; the handoff subnets are connected routes, so
    # they have to be redistributed first or the rest of the fabric never learns where 172.16.10.0/24 lives
    return [f"router bgp {asn} vrf {vrf}", f" bgp router-id {lo}", " no bgp ebgp-requires-policy",
            " bgp bestpath as-path multipath-relax"] + extra + [
            " !", " address-family ipv4 unicast", "  redistribute connected", " exit-address-family",
            " !", " address-family l2vpn evpn", f"  route-target import {RT_ASN}:{vni}", f"  route-target export {RT_ASN}:{vni}",
            "  advertise ipv4 unicast", " exit-address-family", "exit", "!"]


def vrf_links(lo):               # kernel side of symmetric IRB, shared by leaves and border
    s = []
    for vrf, table, vni, *_ in VRFS:
        s += [f"ip link add {vrf} type vrf table {table}", f"ip link set {vrf} up",
              f"ip link add br{vni} type bridge", f"ip link set br{vni} master {vrf}",
              f"ip link set br{vni} addrgenmode none", f"ip link set br{vni} up",
              f"ip link add vxlan{vni} type vxlan id {vni} local {lo} dstport 4789 nolearning",
              f"ip link set vxlan{vni} master br{vni}", f"bridge link set dev vxlan{vni} neigh_suppress on learning off",
              f"ip link set vxlan{vni} up"]
    return s


def leaf(name, asn, lo):
    c = underlay(name, asn, lo, UPLINKS["leaf"], vrfs=True) + ["  advertise-all-vni", " exit-address-family", "exit", "!"]
    s = ["#!/bin/sh", "set -e", f"ip addr add {lo}/32 dev lo", "ip link set eth3 up"] + vrf_links(lo)
    for vrf, table, vni, handoff, vips, _ in VRFS:
        # the TMM-facing prefix list: only the VIP pool (and the tenant's SNAT pool) is accepted from TMM; TMM gets a default
        c += [f"ip prefix-list from-tmm-{vrf} seq 10 permit {vips} le 32"]
        if vrf in SNAT:
            c += [f"ip prefix-list from-tmm-{vrf} seq 20 permit {SNAT[vrf]} le 32"]
        c += ["!"]
        if vrf == "external":
            dev = "eth3"
        else:
            dev = f"eth3.{VLAN[vrf]}"
            s += [f"ip link add link eth3 name {dev} type vlan id {VLAN[vrf]}"]
        s += [f"ip link set {dev} master {vrf}", f"ip addr add {gw(handoff, 1)} dev {dev}", f"ip link set {dev} up"]
        c += vrf_bgp(asn, lo, vrf, vni, [
            f" neighbor tmm peer-group", f" neighbor tmm remote-as {TMM_ASN}",
            f" neighbor tmm local-as {TMM_GW_ASN} no-prepend replace-as", f" neighbor tmm timers 3 9",
            f" bgp listen range {handoff} peer-group tmm",
            # leaf1 also dials TMM's self IP (.11) in every VRF. The EVE lab's fabric opened the tenant sessions
            # towards TMM (hence TCP 179 in the legs' allowed_services); with the leaf passive, the sessions
            # depend on TMM dialing out of a VRF, which it did not do on the first fresh plays (2026-10-31).
            *( [f" neighbor {gw(handoff, 11).split('/')[0]} peer-group tmm"] if name == "leaf1" else [] ),
            " !", " address-family ipv4 unicast", "  neighbor tmm activate", "  neighbor tmm default-originate",
            f"  neighbor tmm prefix-list from-tmm-{vrf} in", "  neighbor tmm soft-reconfiguration inbound",
            " exit-address-family"])
    return c, s


def border(name, asn, lo):
    c = underlay(name, asn, lo, UPLINKS["border"], vrfs=True) + ["  advertise-all-vni", " exit-address-family", "exit", "!"]
    s = ["#!/bin/sh", "set -e", f"ip addr add {lo}/32 dev lo", "ip link set eth3 up"] + vrf_links(lo)
    for vrf, table, vni, handoff, vips, p2p in VRFS:
        dev = f"eth3.{VLAN[vrf]}"
        s += [f"ip link add link eth3 name {dev} type vlan id {VLAN[vrf]}", f"ip link set {dev} master {vrf}",
              f"ip addr add {p2p}.1/30 dev {dev}", f"ip link set {dev} up"]
        c += [f"ip prefix-list to-r5-{vrf} seq 10 permit {vips} le 32", f"ip prefix-list to-r5-{vrf} seq 20 permit {handoff}"]
        if vrf in SNAT:
            c += [f"ip prefix-list to-r5-{vrf} seq 30 permit {SNAT[vrf]} le 32"]
        c += [f"ip prefix-list from-r5 seq 10 permit 0.0.0.0/0", f"ip prefix-list from-r5 seq 20 permit 172.16.250.0/24", "!"]
        c += vrf_bgp(asn, lo, vrf, vni, [
            f" neighbor {p2p}.2 remote-as {R5_ASN}", f" neighbor {p2p}.2 timers 3 9",
            " !", " address-family ipv4 unicast", f"  neighbor {p2p}.2 activate",
            f"  neighbor {p2p}.2 prefix-list to-r5-{vrf} out", f"  neighbor {p2p}.2 prefix-list from-r5 in",
            f"  neighbor {p2p}.2 soft-reconfiguration inbound", " exit-address-family"])
    return c, s


def spine(name, asn, lo):
    c = underlay(name, asn, lo, UPLINKS["spine"]) + [" exit-address-family", "exit", "!"]
    return c, ["#!/bin/sh", "set -e", f"ip addr add {lo}/32 dev lo"]


def r5(name, asn, lo):
    # One global table, like a small edge router: a default toward every VRF of the border, the client subnet
    # behind eth2. Tenant VIP pools do not overlap, so they coexist here.
    c = ["frr defaults datacenter", f"hostname {name}", "service integrated-vtysh-config", "!",
         f"router bgp {asn}", f" bgp router-id {lo}", " no bgp ebgp-requires-policy", " bgp bestpath as-path multipath-relax"]
    s = ["#!/bin/sh", "set -e", f"ip addr add {lo}/32 dev lo", "ip link set eth1 up",
         "ip addr add 172.16.250.1/24 dev eth2", "ip link set eth2 up"]
    nb = []
    for vrf, table, vni, handoff, vips, p2p in VRFS:
        dev = f"eth1.{VLAN[vrf]}"
        s += [f"ip link add link eth1 name {dev} type vlan id {VLAN[vrf]}", f"ip addr add {p2p}.2/30 dev {dev}", f"ip link set {dev} up"]
        c += [f" neighbor {p2p}.1 remote-as external", f" neighbor {p2p}.1 timers 3 9"]
        nb += [f"  neighbor {p2p}.1 activate", f"  neighbor {p2p}.1 default-originate"]
    c += [" !", " address-family ipv4 unicast", "  network 172.16.250.0/24"] + nb + [" exit-address-family", "exit", "!"]
    return c, s


BUILD = {"spine": spine, "leaf": leaf, "border": border, "exit": r5}

for row in csv.DictReader(open(os.path.join(HERE, "nodes.csv"))):
    conf, setup = BUILD[row["role"]](row["name"], int(row["asn"]), row["loopback"])
    d = os.path.join(HERE, "nodes", row["name"]); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "daemons"), "w").write(DAEMONS)
    open(os.path.join(d, "frr.conf"), "w").write("\n".join(conf) + "\nline vty\n")
    p = os.path.join(d, "setup.sh")
    # setup.sh must be safe to run any number of times and at any moment. On the Instruqt VM the first run died at
    # 'ip link add external type vrf' ("Unknown device type": the host lacked the vrf module, 00-host-prep.sh loads
    # it now), `set -e` stopped the script there and leaf1 never got its handoff addresses (bake of 2026-10-31);
    # install/10-fabric.sh runs the scripts again after the deploy. So every command is idempotent (`ip addr
    # replace`, `ip link add` only if the device is missing) and the script first waits for the interfaces it
    # configures, in case containerlab's exec runs before a link exists.
    import re
    devs = sorted({m for line in setup for m in re.findall(r"\beth\d\b", line)})
    body = []
    for line in setup[2:]:
        line = re.sub(r"^ip addr add ", "ip addr replace ", line)
        m = re.match(r"^ip link add link (\S+) name (\S+) (.*)$", line)
        if m:
            line = f"la {m.group(2)} link {m.group(1)} {m.group(3)}"
        else:
            line = re.sub(r"^ip link add (\S+) ", r"la \1 ", line)
        body.append(line)
    head = ["#!/bin/sh", "set -e",
            "la() { ip link show \"$1\" >/dev/null 2>&1 || ip link add \"$@\"; }   # add a link only if it is missing",
            "wd() { for d in \"$@\"; do i=0; until ip link show \"$d\" >/dev/null 2>&1; do i=$((i+1)); [ $i -ge 900 ] && { echo \"setup: $d never appeared\" >&2; exit 1; }; sleep 1; done; done; }",
            f"wd {' '.join(devs)}" if devs else ": no interfaces to wait for"]
    open(p, "w").write("\n".join(head + body + ["vtysh -b >/dev/null 2>&1 || true"]) + "\n")
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    print(row["name"], len(conf), "lines frr.conf,", len(setup), "setup commands")
