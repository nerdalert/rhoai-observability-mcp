# Demo 2: KServe + MCP Ops Investigation

This demo is designed to keep the presentation moving even when MaaS token issuance is unstable.

Technical focus:
- Validate model serving through `LLMInferenceService` (KServe path)
- Validate MCP observability and investigation tools against that workload
- Include MaaS token checks and fixes, but do not block the demo on them

## Run

From `rhoai-observability-mcp` root:

```bash
./demos/kserve-mcp-ops/deploy-e2e.sh
```

## What It Deploys/Validates

1. Ensures sample model exists (`facebook-opt-125m-simulated` in `llm` namespace)
2. Deploys MCP server in `rhoai-obs-mcp`
3. Grants monitoring API permissions required by MCP tools
4. Validates model completion endpoint via LLMInferenceService URL
5. Attempts MaaS token issuance + model listing
6. Validates MCP JSON-RPC flow and tools:
- `get_pods(namespace="llm")`
- `query_prometheus(query="up")`
- `get_events(namespace="llm")`
- `investigate_errors(namespace="llm", time_range="30m")`

## MaaS Token (`No Healthy Upstream`) Quick Fix Path

## 1) Always resolve gateway URL from Gateway listeners

```bash
oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{range .spec.listeners[*]}{.protocol}{" "}{.hostname}{"\n"}{end}'
```

Use the HTTPS hostname to build `GATEWAY_URL`.

## 2) Verify MaaS API backend health before issuing tokens

```bash
oc get pods -n opendatahub -l app.kubernetes.io/name=maas-api
oc rollout status deploy/maas-api -n opendatahub --timeout=240s
```

## 3) If still failing, use deep fix doc

See:

- `/home/ubuntu/mcp/maas-token-fix.md`

That document includes:
- RBAC supplement for `maas-api` service account
- CRD mismatch diagnostics (`resource not found`)
- Retry-safe token validation commands

## Chat Completion Example

If MaaS token and model discovery succeed:

```bash
TOKEN="<minted-token>"
MODEL_URL="<from /maas-api/v1/models response>"
MODEL_NAME="<from /maas-api/v1/models response>"

curl -sk -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_NAME}\",\"prompt\":\"Explain a p95 latency spike in one sentence\",\"max_tokens\":64}" \
  "${MODEL_URL}/v1/completions" | jq .
```

If MaaS token is unstable, use direct LLMInferenceService demo path:

```bash
LLM_URL=$(oc get llminferenceservice facebook-opt-125m-simulated -n llm -o jsonpath='{.status.url}')

curl -sS -H 'Content-Type: application/json' \
  -d '{"model":"facebook-opt-125m-simulated","prompt":"Hello from direct KServe path","max_tokens":32}' \
  "${LLM_URL}/v1/completions" | jq .
```

## Live Talk Flow (Demo 2)

1. Show model is serving (`oc get llminferenceservices -n llm`)
2. Run one completion request
3. Open MCP SSE flow and call investigation tools
4. Ask: "What changed in `llm` namespace recently?" and show `get_events`/`investigate_errors`
5. Optional: show MaaS token issue diagnosis quickly and continue without blocking
