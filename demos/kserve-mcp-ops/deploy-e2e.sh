#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAAS_DIR="${ROOT_DIR}/../models-as-a-service"
MCP_NS="rhoai-obs-mcp"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

resolve_gateway_url() {
  local host
  host=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{range .spec.listeners[*]}{.protocol}{" "}{.hostname}{"\n"}{end}' \
    | awk '$1=="HTTPS" && $2!="" {print $2; exit}')
  if [[ -z "$host" ]]; then
    host=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{range .spec.listeners[*]}{.protocol}{" "}{.hostname}{"\n"}{end}' \
      | awk '$1=="HTTP" && $2!="" {print $2; exit}')
  fi
  [[ "$host" =~ ^https?:// ]] && echo "$host" || echo "https://${host}"
}

maybe_token() {
  local host="$1"
  local response token
  for i in {1..10}; do
    response=$(curl -sSk -H "Authorization: Bearer $(oc whoami -t)" -H 'Content-Type: application/json' \
      -X POST -d '{"expiration":"10m"}' "${host}/maas-api/v1/tokens")
    token=$(echo "$response" | jq -r '.token // empty' 2>/dev/null || true)
    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi
    sleep 4
  done
  return 1
}

log "Cluster context"
oc whoami
oc get nodes

log "Deploy/refresh sample LLMInferenceService (simulator)"
cd "$MAAS_DIR"
PROJECT_DIR=$(git rev-parse --show-toplevel)
kustomize build "${PROJECT_DIR}/docs/samples/models/simulator/" | oc apply -f -
oc wait --for=condition=ready llminferenceservice/facebook-opt-125m-simulated -n llm --timeout=300s || true
oc get llminferenceservices -n llm
oc get pods -n llm

log "Deploy MCP server"
cd "$ROOT_DIR"
oc new-project "$MCP_NS" >/dev/null 2>&1 || true
oc project "$MCP_NS" >/dev/null
oc apply -f deploy/ -n "$MCP_NS"
if ! oc rollout status deployment/rhoai-obs-mcp -n "$MCP_NS" --timeout=300s; then
  warn "MCP deployment not ready; dumping scheduler diagnostics"
  oc get pods -n "$MCP_NS" -o wide || true
  oc describe pod -n "$MCP_NS" -l app=rhoai-obs-mcp | sed -n '1,180p' || true
  exit 1
fi
oc adm policy add-cluster-role-to-user cluster-monitoring-view -z rhoai-obs-mcp -n "$MCP_NS"
cat <<'YAML' | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rhoai-obs-mcp-monitoring-api
rules:
  - apiGroups: ["monitoring.coreos.com"]
    resources: ["prometheuses/api", "alertmanagers/api"]
    verbs: ["get", "create", "update"]
YAML
oc adm policy add-cluster-role-to-user rhoai-obs-mcp-monitoring-api -z rhoai-obs-mcp -n "$MCP_NS"

log "Validate direct model path (KServe URL)"
LLM_URL=$(oc get llminferenceservice facebook-opt-125m-simulated -n llm -o jsonpath='{.status.url}' 2>/dev/null || true)
if [[ -n "$LLM_URL" ]]; then
  curl -sS "${LLM_URL}/health" || true
  curl -sS -H 'Content-Type: application/json' \
    -d '{"model":"facebook-opt-125m-simulated","prompt":"Hello from demo2","max_tokens":32}' \
    "${LLM_URL}/v1/completions" | jq . || true
else
  warn "LLM URL not available yet"
fi

log "Validate MaaS token endpoint (optional for this demo)"
GATEWAY_URL=$(resolve_gateway_url)
log "GATEWAY_URL=${GATEWAY_URL}"
if TOKEN=$(maybe_token "$GATEWAY_URL"); then
  log "MaaS token minted (prefix): ${TOKEN:0:18}..."
  curl -sSk "${GATEWAY_URL}/maas-api/v1/models" -H "Authorization: Bearer ${TOKEN}" | jq . || true
else
  warn "MaaS token endpoint not healthy; continuing with KServe + MCP observability flow"
  warn "See /home/ubuntu/mcp/maas-token-fix.md for root-cause checks and fixes"
fi

log "Validate MCP tools over SSE"
ROUTE_HOST=$(oc get route rhoai-obs-mcp -n "$MCP_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -z "$ROUTE_HOST" ]]; then
  warn "Route host for MCP not found"
  exit 1
fi
OUT=/tmp/kserve_mcp_demo2_sse.out
COOK=/tmp/kserve_mcp_demo2_cookie.txt
rm -f "$OUT" "$COOK"
(curl -skN -c "$COOK" "https://${ROUTE_HOST}/sse" > "$OUT") &
SSE_PID=$!
MSG_PATH=""
for _ in {1..10}; do
  MSG_PATH=$(awk -F'data: ' '/^data: /{print $2; exit}' "$OUT" | tr -d '\r')
  [[ -n "$MSG_PATH" ]] && break
  sleep 1
done
if [[ -z "$MSG_PATH" ]]; then
  kill $SSE_PID || true
  warn "Could not get SSE message endpoint"
  sed -n '1,20p' "$OUT" || true
  exit 1
fi

curl -sk -b "$COOK" -X POST "https://${ROUTE_HOST}${MSG_PATH}" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"demo2","version":"0.1"}}}' >/dev/null
curl -sk -b "$COOK" -X POST "https://${ROUTE_HOST}${MSG_PATH}" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >/dev/null
curl -sk -b "$COOK" -X POST "https://${ROUTE_HOST}${MSG_PATH}" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_pods","arguments":{"namespace":"llm"}}}' >/dev/null
curl -sk -b "$COOK" -X POST "https://${ROUTE_HOST}${MSG_PATH}" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query_prometheus","arguments":{"query":"up"}}}' >/dev/null
curl -sk -b "$COOK" -X POST "https://${ROUTE_HOST}${MSG_PATH}" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_events","arguments":{"namespace":"llm"}}}' >/dev/null
curl -sk -b "$COOK" -X POST "https://${ROUTE_HOST}${MSG_PATH}" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"investigate_errors","arguments":{"namespace":"llm","time_range":"30m"}}}' >/dev/null
sleep 2
kill $SSE_PID || true

rg '"id":1|"id":2|"id":3|"id":4|"id":5' "$OUT"
log "Demo2 complete"
