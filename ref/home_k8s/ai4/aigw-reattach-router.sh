#!/usr/bin/env bash
# Re-program the semantic-router ext_proc on AI Gateway profile lab-ai (needed after the router pod gets a new IP).
export KUBECONFIG=/etc/kubernetes/admin.conf
API=http://127.0.0.1:18443; TA=$API/api/v1/tenants/lab
U=$(kubectl get secret f5-aigateway-admin -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret f5-aigateway-admin -o jsonpath='{.data.password}' | base64 -d)
TOK=$(jq -n --arg u "$U" --arg p "$P" '{username:$u,password:$p}' | curl -sS $API/api/v1/auth/login -H 'Content-Type: application/json' --data-binary @- | jq -r .access_token)
j() { curl -sS "$@" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json'; }
echo "current: $(j $TA/profiles/lab-ai/semantic-router | head -c 300)"
echo "delete:  $(j -X DELETE $TA/profiles/lab-ai/semantic-router -o /dev/null -w '%{http_code}')"
sleep 5
echo "put:     $(j -X PUT $TA/profiles/lab-ai/semantic-router --data-binary '{"name":"semantic-router","port":50051,"timeoutMs":1000}' | head -c 300)"
kubectl -n default wait --for=condition=Programmed aigatewayprofiles.inference.k8s.f5.com/lab-ai --timeout=180s
