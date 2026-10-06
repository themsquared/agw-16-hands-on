# agw-16-hands-on

> 📖 **Read the write-up:** [agentgateway v1.6.0: Cost Tracking With No Catalog Config](https://webofmike.com/agentgateway-v16-cost-tracking/)

Two features from [agentgateway v1.6.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.6.0) (GA, 2026-10-02), validated against a live gateway and a real Claude Sonnet 5 backend: automatic cost tracking with zero catalog configuration, and per-key CEL rate limiting.

No Kubernetes, no cluster. One Docker container, one config file, one API key.

## What this proves

1. **Zero-config cost tracking.** v1.6.0 ships a built-in model catalog. A route to `claude-sonnet-5` with no `modelCatalog` block anywhere in the config still produces `llm.cost.total` and `llm.costRates.input`/`.output` in CEL, and `agw.ai.usage.cost.total` in the OpenTelemetry-style access log. In 1.5 this required declaring rates by hand.
2. **Per-key CEL rate limiting.** A single `localRateLimit` rule keyed by `request.headers["x-api-key"]` gives every distinct header value its own bucket. Exhaust one key's quota and a different key still goes through, no restart, no second rule.
3. **A gotcha worth knowing.** A request that fails upstream (a dropped TLS connection, in this run) still consumes a token from the rate-limit bucket. The limiter counts admitted requests, not successful ones.

## The config

```yaml
# config/config.yaml
frontendPolicies:
  accessLog:
    add:
      model.requested: llm.requestModel
      model.served: llm.responseModel
      tokens.input: llm.inputTokens
      tokens.output: llm.outputTokens
      cost.total: llm.cost.total
      cost.rate.input: llm.costRates.input
      cost.rate.output: llm.costRates.output
llm:
  port: 4000
  policies:
    localRateLimit:
    - type: requests
      maxTokens: 3
      tokensPerFill: 3
      fillInterval: 60s
      key: request.headers["x-api-key"]
  models:
  - name: claude
    provider: anthropic
    params:
      model: claude-sonnet-5
      apiKey: $ANTHROPIC_API_KEY
```

No `modelCatalog`, no rates entered anywhere. That's the point: `claude-sonnet-5` is a model the built-in catalog already knows.

## Quickstart

Requirements: Docker, an `ANTHROPIC_API_KEY`. Tested on macOS (Apple silicon) against `cr.agentgateway.dev/agentgateway:v1.6.0`.

```bash
git clone https://github.com/themsquared/agw-16-hands-on.git
cd agw-16-hands-on
export ANTHROPIC_API_KEY=sk-ant-...
./run-demo.sh
```

Check the config against the v1.6.0 schema without starting anything:

```bash
docker run --rm -v "$PWD/config/config.yaml:/config/config.yaml:ro" \
  -e ANTHROPIC_API_KEY=dummy-for-validate \
  cr.agentgateway.dev/agentgateway:v1.6.0 -f /config/config.yaml --validate-only
```

Tear down:

```bash
docker rm -f agw16-demo
```

## What the run actually showed

First request, key A, no catalog configured anywhere:

```
http.status=200 gen_ai.usage.input_tokens=8 gen_ai.usage.output_tokens=14
agw.ai.usage.cost.total=0.000156
cost.total=0.000156 cost.rate.input=2 cost.rate.output=10
```

`cost.rate.input=2` and `cost.rate.output=10` are USD per million tokens, pulled from the built-in catalog for `claude-sonnet-5`, matching Anthropic's published Sonnet pricing. The math: `(8 * 2 + 14 * 10) / 1,000,000 = 0.000156`. Nothing in the config told agentgateway what Sonnet costs.

Requests 2 and 3 with the same key: both `200`, still inside the 3-request bucket.

Request 4, same key, same minute:

```
http.status=429 error="rate limit exceeded" reason=RateLimit
```

Request with a *different* key, same minute, bucket untouched:

```
http.status=200 ... cost.total=0.000176
```

Key B never saw key A's rate limit. That is the whole feature: one rule, one CEL key expression, independent buckets per value.

### The gotcha

One run of this demo hit a transient upstream TLS reset partway through:

```
http.status=503 error="upstream call failed: SendRequest: connection error: peer closed connection without sending TLS close_notify" reason=UpstreamFailure
```

`x-ratelimit-remaining` still dropped. The 503 never reached Anthropic successfully, but it still counted as one of the 3 admitted requests in the bucket. If you're budgeting a tight per-key quota, a flaky upstream eats into it exactly like a successful call. Worth knowing before setting `maxTokens` close to your real traffic.

## What this doesn't cover

- No Kubernetes. v1.6.0's `AgentgatewayModel` CRD (now enabled by default in the Helm chart) and K8s-native session affinity are separate, cluster-side features not exercised here.
- No OpenAI/Gemini/Bedrock. The built-in catalog covers more than Anthropic; this repo only validates the one provider with a key on hand.
- `remoteRateLimit` (a quota shared across replicas) is a different policy; `localRateLimit` buckets live in the single proxy instance that created them.

## Related reading

- [agentgateway v1.6.0 release notes](https://github.com/agentgateway/agentgateway/releases/tag/v1.6.0)

## License

Apache-2.0
