# shellcheck shell=bash
# expose_service <unit> <namespace> <service> <host-port> [service-port]
#
# Publishes a cluster Service on the host with a socat systemd unit that targets the Service's ClusterIP. Not
# kubectl port-forward: that binds to one pod when it starts and drops the connection when the pod moves; the
# ClusterIP is stable and kube-proxy on the kind node keeps it pointing at a live pod. On Instruqt the unit binds
# the VM address (LAB_PUBLIC=1, set by setup-factory; the sandbox network is private to the learner); anywhere else
# it binds loopback. Needs root for systemd, which setup-factory and the bake have; on a workstation it falls back
# to a plain background socat.
expose_service() {
  local unit="$1" ns="$2" svc="$3" hport="$4" sport="${5:-}" ip port bind
  ip=$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.clusterIP}') || return 1
  [ -n "$sport" ] || sport=$(kubectl -n "$ns" get svc "$svc" -o jsonpath='{.spec.ports[0].port}')
  [ -n "$ip" ] && [ -n "$sport" ] || { warn "Service $ns/$svc has no ClusterIP or port"; return 1; }
  # Instruqt's agent reaches a service tab's port through loopback on the VM, so a public UI must listen on every
  # address (the first full play, 2026-10-31: units bound to the VM address alone showed "trying to connect").
  # The sandbox network is private to the learner. LAB_BIND_ADDR overrides.
  bind=127.0.0.1
  [ "${LAB_PUBLIC:-0}" = 1 ] && bind="${LAB_BIND_ADDR:-0.0.0.0}"
  # the kind node network is only reachable from the host through docker; the ClusterIP is routed via the node
  # (kube-proxy), so the route to the Service CIDR goes through the control-plane container's address
  local node_ip; node_ip=$(docker inspect bnk-control-plane -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null | head -1)
  ip route show 10.96.0.0/12 2>/dev/null | grep -q . || sudo ip route replace 10.96.0.0/12 via "$node_ip" 2>/dev/null || true
  if [ "$(id -u)" = 0 ] && command -v systemctl >/dev/null; then
    command -v socat >/dev/null || apt-get install -y -qq socat >/dev/null
    cat > "/etc/systemd/system/lab-expose-$unit.service" <<EOF
[Unit]
Description=lab UI $unit: ${bind}:${hport} -> ${ns}/${svc} (${ip}:${sport})
After=network-online.target docker.service
[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${hport},bind=${bind},reuseaddr,fork TCP:${ip}:${sport}
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable --now "lab-expose-$unit" >/dev/null 2>&1; systemctl restart "lab-expose-$unit"
  else
    pkill -f "TCP-LISTEN:${hport},bind=${bind}" 2>/dev/null || true
    nohup socat "TCP-LISTEN:${hport},bind=${bind},reuseaddr,fork" "TCP:${ip}:${sport}" >/dev/null 2>&1 &
  fi
  ok "$unit on ${bind}:${hport} -> ${ns}/${svc}"
}
