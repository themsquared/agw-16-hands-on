#!/usr/bin/env bash
# Runs agentgateway v1.6.0 standalone and fires the requests this repo's
# README walks through: automatic cost tracking with zero catalog config,
# then the per-key CEL rate limit.
set -euo pipefail

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Set ANTHROPIC_API_KEY first (export ANTHROPIC_API_KEY=sk-ant-...)." >&2
  exit 1
fi

PORT="${PORT:-4010}"
cd "$(dirname "$0")"

docker rm -f agw16-demo >/dev/null 2>&1 || true
docker run -d --name agw16-demo -p "${PORT}:4000" \
  -v "$PWD/config/config.yaml:/config/config.yaml:ro" \
  -e ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
  cr.agentgateway.dev/agentgateway:v1.6.0 -f /config/config.yaml

echo "waiting for the gateway to come up..."
sleep 2
docker logs agw16-demo 2>&1 | tail -8

req() {
  curl -s -w "\nHTTP_STATUS:%{http_code}\n" -X POST "http://localhost:${PORT}/v1/messages" \
    -H "content-type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -H "x-api-key: $1" \
    -d '{"model":"claude","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
}

echo
echo "=== request 1 with key A (zero-config cost tracking lands in the access log below) ==="
req demo-key-A

echo
echo "=== requests 2 and 3 with key A (still inside the 3-request bucket) ==="
req demo-key-A
req demo-key-A

echo
echo "=== request 4 with key A (bucket exhausted, expect 429) ==="
req demo-key-A

echo
echo "=== request with key B (separate bucket, expect 200) ==="
req demo-key-B

echo
echo "=== access log lines (look for cost.total, cost.rate.input/output, agw.ai.usage.cost.total) ==="
docker logs agw16-demo 2>&1 | grep 'route=internal/llm:request'

echo
echo "Tear down with: docker rm -f agw16-demo"
