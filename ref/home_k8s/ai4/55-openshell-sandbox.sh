#!/usr/bin/env bash
# Provider profile for the AI Gateway + one long-running sandbox "aigw-agent".
set -uo pipefail
cd /root/ai4
openshell provider profile lint -f f5-aigw-profile.yaml
openshell provider profile import -f f5-aigw-profile.yaml --global 2>&1 | tail -1
AIGW_API_KEY=$(tr -d ' \n\r' < /root/ai4/kagent-virtual-key) openshell provider create --name f5-aigw --type f5-aigw --credential AIGW_API_KEY 2>&1 | tail -1
openshell sandbox create --name aigw-agent --provider f5-aigw --env OPENAI_BASE_URL=http://10.10.12.33/v1 --no-tty -- sleep infinity >/tmp/sbx.log 2>&1 &
for i in $(seq 1 60); do openshell sandbox list 2>/dev/null | grep -q 'aigw-agent.*Ready' && break; sleep 5; done
openshell sandbox list
