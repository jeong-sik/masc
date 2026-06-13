# RFC-0214: OTel GenAI Semantic Convention Migration

| | |
|---|---|
| **Status** | Draft |
| **Author** | Claude Opus 4.8 |
| **Date** | 2026-06-04 |
| **Supersedes** | — |

## 1. Problem

masc-mcp의 LLM 텔레메트리는 이전에 **legacy backend 전용 커스텀 메트릭**(`masc_llm_provider_*`)을 사용했다. legacy backend 는 RFC-0217 / PR #20189 로 제거되었고, 남은 방향은 OTel GenAI Semantic Convention(`gen_ai.*`) 정렬이다. 기존 커스텀 명명은:

1. Grafana/Datadog/New Relic이 LLM 메트릭을 자동 분류하지 못함
2. OTLP export 시 메트릭명 매핑이 필요
3. span attributes와 metric labels 간 불일치

## 2. Current State

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

### 2.2 OTel Span Events (Partial)

Only streaming events emit OTel span attributes:

| Span Event | Attributes |
|------------|------------|
| `ttfrc.received` | `gen_ai.provider.name`, `gen_ai.request.model`, `masc.gen_ai.streaming.ttfrc_ms` |
| `streaming.chunk` | `gen_ai.provider.name`, `gen_ai.request.model`, `masc.gen_ai.streaming.chunk_index`, `masc.gen_ai.streaming.inter_chunk_ms` |

### 2.3 Missing OTel Integration

- Token usage → NOT as OTel metric or span attribute
- Error events → NOT as OTel span status
- Cache metrics → NOT in OTel
- Request duration → NOT as OTel metric

## 3. Target State (OTel GenAI Semconv)

Reference: [OTel GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)

### 3.1 OTel Metric: `gen_ai.client.token.usage`

Counter with `gen_ai.token.type` attribute:

| `gen_ai.token.type` value | Source |
|--------------------------|--------|
| `input` | `masc_llm_provider_input_tokens_total` |
| `output` | `masc_llm_provider_output_tokens_total` |
| `cache_read` | `masc_llm_provider_cache_read_tokens_total` |
| `cache_creation` | `masc_llm_provider_cache_creation_tokens_total` |
| `reasoning` | `masc_llm_provider_reasoning_tokens_total` |

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
| `gen_ai.response.finish_reasons` | `stop_reason` |
| `gen_ai.response.model` | `resolved_model_id` |

## 4. Approach: OTel Migration

### 4.1 Strategy

Emit OTel metrics/attributes directly.

Why OTel-only migration:
- legacy backend was removed by RFC-0217 / PR #20189
- The compatibility target is now OTel metric store + OTLP, not dual emission
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

### 4.3 Code Changes

#### Phase A: Span Attributes (Low risk)

In `lib/llm_metric_bridge.ml`, add OTel span attributes to `emit_token_usage`:

```ocaml
let emit_token_usage ~provider ~model_id ~input_tokens ~output_tokens =
  (* OTel metric store counters *)
  Otel_metric_store.inc_counter input_token_metric ...;
  Otel_metric_store.inc_counter output_token_metric ...;
  (* OTel span attributes *)
  Otel_spans.add_event
    ~name:"gen_ai.client.token.usage"
    ~attrs:
      [ "gen_ai.provider.name", `String provider
      ; "gen_ai.request.model", `String model_id
      ; "gen_ai.usage.input_tokens", `Int input_tokens
      ; "gen_ai.usage.output_tokens", `Int output_tokens
      ]
    ()
```

Similarly for `emit_error` (span status), `emit_streaming_first_chunk` (already partially done).

#### Phase B: OTel Metric Export (Medium risk)

Add a thin OTel metric exporter in the bridge:

```ocaml
(* OTel emission helper *)
let emit_metric_otel ~name ~value ~attrs =
  Otel_metrics.record ~name ~value ~attrs
```

This requires the `opentelemetry` OCaml library (already in dune-project).

#### Phase C: Custom→Standard Migration (Future)

After Phase B is validated:
1. Add legacy → OTel name mapping table where compatibility is still needed
2. Grafana dashboards use OTel metric names
3. Deprecate legacy `masc_llm_provider_*` names once dashboard consumers are updated

## 5. Scope & Effort

| Phase | Files | Effort | Risk |
|-------|-------|--------|------|
| A: Span attributes | `llm_metric_bridge.ml`, `keeper_hooks_oas.ml` | ~50 lines | Low |
| B: OTel metric export | `llm_metric_bridge.ml`, new `otel_llm_metrics.ml` | ~200 lines | Medium |
| C: Deprecation | Dashboard, alert configs | ~100 files | High |

## 6. Decision Points

1. **Dual emission vs replacement?** — Replacement. RFC-0217 / PR #20189 retired the legacy backend.
2. **OTLP endpoint configuration?** — Use existing `opentelemetry` lib config (env vars).
3. **Custom attributes (`masc.gen_ai.*`) migration?** — Phase C, with deprecation period.

## 7. Non-Goals

- Restoring legacy metric names
- OTel Logs integration (JSONL → OTLP logs bridge is a separate concern)
- Replacing JSONL persistence with OTel-only (JSONL remains the durable truth)

## 8. References

- [OTel GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [OTel GenAI Metrics](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-metrics/)
- PR #19957 — Telemetry pipeline gap fixes (error/retry JSONL, cache_creation pipeline)
- `lib/llm_metric_bridge.ml` — Bridge layer with partial OTel span events
- `lib/opentelemetry_client_cohttp_eio.ml` — OTLP exporter (Eio transport)
