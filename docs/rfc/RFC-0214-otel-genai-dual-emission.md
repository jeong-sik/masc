# RFC-0214: OTel GenAI Semantic Convention Migration

| | |
|---|---|
| **Status** | Implemented |
| **Author** | Claude Opus 4.8 |
| **Date** | 2026-06-04 |
| **Last Updated** | 2026-06-06 |
| **Supersedes** | — |

## 1. Problem

masc-mcp의 LLM 텔레메트리는 이전에 **legacy backend 전용 커스텀 메트릭**(`masc_llm_provider_*`)을 사용했다. legacy backend 는 RFC-0217 / PR #20189 로 제거되었고, 남은 방향은 OTel GenAI Semantic Convention(`gen_ai.*`) 정렬이다. 기존 커스텀 명명은:

1. Grafana/Datadog/New Relic이 LLM 메트릭을 자동 분류하지 못함
2. OTLP export 시 메트릭명 매핑이 필요
3. span attributes와 metric labels 간 불일치

## 2. Current State

Implementation status as of 2026-06-06:

- Legacy `masc_llm_provider_*` metrics remain emitted from `Otel_metric_store`
  for existing dashboards.
- `lib/llm_metric_bridge.ml` now also emits standard GenAI OTel client metrics:
  `gen_ai.client.token.usage`,
  `gen_ai.client.operation.duration`,
  `gen_ai.client.operation.time_to_first_chunk`, and
  `gen_ai.client.operation.time_per_output_chunk`.
- Token usage, cache details, reasoning-token details, streaming timing, and
  bounded error classification are projected to GenAI span attributes/events.
- `tool.name` telemetry used by tool-input validation remains a separate
  historical tool telemetry surface. It is not the same as the GenAI/MCP
  semantic-convention `gen_ai.tool.name` attribute used for model/tool-call
  spans.
- MCP tool-call spans emitted by `lib/otel_dispatch_hook.ml` use
  `tools/call <tool-name>` span names, `mcp.method.name=tools/call`, and
  `gen_ai.tool.name=<tool-name>`. Failed tool results set span status ERROR
  and use OTel/MCP `error.type=tool_error` for `CallToolResult.isError=true`.
  The typed `Tool_result.tool_failure_class` string remains available under the
  MASC-owned `masc.mcp.tool.failure_class` attribute.
  When a JSON-RPC `tools/call` request context is available, spans also carry
  `jsonrpc.request.id`, `mcp.session.id`, `mcp.protocol.version`, and SERVER
  kind. Internal dispatch spans without MCP request context keep CLIENT kind and
  omit request/session attrs.

### 2.1 Legacy Metric Names

| Legacy Name | Type | Labels |
|-----------------|------|--------|
| `masc_llm_provider_input_tokens_total` | counter | provider, model |
| `masc_llm_provider_output_tokens_total` | counter | provider, model |
| `masc_llm_provider_cache_read_tokens_total` | counter | provider, model |
| `masc_llm_provider_cache_creation_tokens_total` | counter | provider, model |
| `masc_llm_provider_reasoning_tokens_total` | counter | provider, model |
| `masc_llm_provider_request_latency_seconds` | histogram | provider, model |
| `masc_llm_provider_errors_by_reason_total` | counter | model, error_reason |
| `masc_llm_provider_retries_total` | counter | provider, model, attempt |
| `masc_llm_provider_streaming_first_chunk_seconds` | histogram | provider, model |
| `masc_llm_provider_streaming_inter_chunk_seconds` | histogram | provider, model |
| `masc_llm_provider_cache_hits_total` | counter | provider, model |
| `masc_llm_provider_cache_misses_total` | counter | provider, model |
| `masc_llm_provider_circuit_state` | gauge | provider, model |

### 2.2 OTel Span Events And Attributes

| Surface | Attributes |
|---------|------------|
| `gen_ai.client.inference.operation.details` | `gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.response.model`, usage token attributes |
| `gen_ai.client.operation.exception` | `exception.message`, `exception.type`, plus low-cardinality `error.type` on the span |
| `ttfrc.received` | `gen_ai.provider.name`, `gen_ai.request.model`, `gen_ai.response.time_to_first_chunk`, `masc.gen_ai.streaming.ttfrc_ms` |
| `streaming.chunk` | `gen_ai.provider.name`, `gen_ai.request.model`, `masc.gen_ai.streaming.chunk_index`, `masc.gen_ai.streaming.inter_chunk_ms` |

### 2.3 Remaining Constraints

- The standard `gen_ai.client.token.usage` metric only uses
  `gen_ai.token.type=input|output`. Cache and reasoning tokens are represented
  as usage detail attributes, not as additional token-type label values.
- The current bridge intentionally does not record opt-in prompt/response
  content attributes such as `gen_ai.input.messages` or
  `gen_ai.output.messages`.

## 3. Target State (OTel GenAI Semconv)

Reference: [OTel GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)

### 3.1 OTel Metric: `gen_ai.client.token.usage`

Histogram with `gen_ai.token.type` attribute:

| `gen_ai.token.type` value | Source |
|--------------------------|--------|
| `input` | `masc_llm_provider_input_tokens_total` |
| `output` | `masc_llm_provider_output_tokens_total` |

Do not encode `cache_read`, `cache_creation`, or `reasoning` as
`gen_ai.token.type` values. The OpenTelemetry well-known values are
`input` and `output`; provider cache/reasoning details belong on the
`gen_ai.usage.*` attributes below.

### 3.2 OTel Span Event: `gen_ai.client.inference.operation.details`

Attributes to add per-inference:

| Attribute | Source |
|-----------|--------|
| `gen_ai.usage.input_tokens` | `response.usage.input_tokens` |
| `gen_ai.usage.output_tokens` | `response.usage.output_tokens` |
| `gen_ai.usage.cache_read.input_tokens` | `response.usage.cache_read_input_tokens` |
| `gen_ai.usage.cache_creation.input_tokens` | `response.usage.cache_creation_input_tokens` |
| `gen_ai.usage.reasoning.output_tokens` | `response.telemetry.reasoning_tokens` |
| `gen_ai.response.time_to_first_chunk` | `streaming_ttfrc_ms / 1000` |
| `gen_ai.request.stream` | `true` on streaming callbacks |
| `masc.gen_ai.response.finish_reason` | `stop_reason` |
| `gen_ai.response.model` | `resolved_model_id` |

`gen_ai.response.finish_reasons` is the upstream OpenTelemetry key, but it is a
`string[]` attribute. The current opentelemetry-ocaml `key_value` type only
supports scalar values, so MASC emits the scalar stop reason under the
MASC-owned extension above instead of string-encoding the official array key.

## 4. Approach: OTel Migration

### 4.1 Strategy

Emit OTel metrics/attributes directly.

Why OTel-backed migration:
- legacy backend was removed by RFC-0217 / PR #20189
- The compatibility target is now OTel metric store + OTLP
- Existing `masc_llm_provider_*` metric names remain in the OTel metric store
  until dashboard consumers migrate to `gen_ai.*`
- OTLP-enabled environments get automatic LLM dashboards
- OTel is the primary metric backend

### 4.2 Implementation Layers

```
                    ┌─────────────────┐
                    │  OAS Callbacks   │
                    │  (on_token_usage, │
                    │   on_error, etc)  │
                    └────────┬─────────┘
                             │
                    ┌────────▼─────────┐
                    │  Bridge Layer     │
                    │  (llm_metric_     │
                    │   bridge.ml)      │
                    └───┬──────────┬───┘
                        │          │
              ┌─────────▼──┐  ┌───▼──────────┐
              │ OTel metric│  │  OTel span    │
              │ store      │  │  attributes   │
              └────────────┘  └──────────────┘
```

### 4.3 Implemented Changes

| File | Change |
|------|--------|
| `lib/otel_genai/otel_genai.ml` | Centralized GenAI metric, event, and attribute names including usage detail attributes. |
| `lib/otel_dispatch_hook/otel_dispatch_hook.ml` | Emits MCP tool-call spans with `tools/call <tool-name>` names, `mcp.method.name=tools/call`, `gen_ai.tool.name`, context-aware CLIENT/SERVER span kind, request/session/protocol attrs when a JSON-RPC `tools/call` request context is present, OTel/MCP `error.type=tool_error`, MASC `masc.mcp.tool.failure_class`, and ERROR status for failed tool results. |
| `lib/otel_spans/otel_spans.ml` | Added testable span attribute/status hooks and GenAI exception recording. |
| `lib/llm_metric_bridge.ml` | Emits standard GenAI client metrics, operation-details events, usage attributes, streaming timings, and bounded error status. |
| `lib/keeper/keeper_hooks_oas.ml` | Projects trusted cache/reasoning token details into GenAI usage attributes without inventing extra `gen_ai.token.type` values. |
| `test/test_llm_metric_bridge.ml` | Covers standard metric names, event names, span attrs/status, and the cache/reasoning token-type guardrail. |
| `test/test_otel_dispatch_hook.ml` | Covers MCP tool-call span name, `gen_ai.tool.name`, `mcp.method.name`, internal CLIENT kind, request-context SERVER kind, `jsonrpc.request.id`, `mcp.session.id`, `mcp.protocol.version`, OTel/MCP `tool_error`, and MASC typed failure-class preservation. |

## 5. Remaining Migration Work

| Area | Status |
|------|--------|
| Dashboard queries | Can migrate from `masc_llm_provider_*` to `gen_ai.*`; legacy names remain available for now. |
| Prompt/response content events | Intentionally not emitted by default because `gen_ai.input.messages` and `gen_ai.output.messages` are opt-in and can contain sensitive data. |
| MCP tool-call semantic convention | Implemented for handled `Tool_dispatch` results; still intentionally separate from LLM GenAI client metrics and from historical `tool.name` validation telemetry. |

## 6. Decision Points

1. **Dual emission vs replacement?** — Dual metric names in the OTel metric
   store for compatibility; no restoration of the retired legacy backend.
2. **OTLP endpoint configuration?** — Use existing `opentelemetry` lib config (env vars).
3. **Custom attributes (`masc.gen_ai.*`) migration?** — Keep as MASC-owned
   extensions where no current GenAI convention exists.

## 7. Non-Goals

- Restoring legacy metric names
- OTel Logs integration (JSONL → OTLP logs bridge is a separate concern)
- Replacing JSONL persistence with OTel-only (JSONL remains the durable truth)

## 8. References

- [OTel GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) — checked 2026-06-06, confidence High.
- [OTel GenAI Metrics](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-metrics/) — checked 2026-06-06, confidence High.
- [OTel GenAI Events](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-events/) — checked 2026-06-06, confidence High.
- [OTel GenAI Exceptions](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-exceptions/) — checked 2026-06-06, confidence High.
- [OTel GenAI Attribute Registry](https://opentelemetry.io/docs/specs/semconv/registry/attributes/gen-ai/) — checked 2026-06-06, confidence High.
- [OTel MCP Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/mcp/) — checked 2026-06-06, confidence High.
- PR #19957 — Telemetry pipeline gap fixes (error/retry JSONL, cache_creation pipeline)
- `lib/llm_metric_bridge.ml` — Bridge layer with GenAI client metric/span/event emission
- `lib/opentelemetry_client_cohttp_eio.ml` — OTLP exporter (Eio transport)
