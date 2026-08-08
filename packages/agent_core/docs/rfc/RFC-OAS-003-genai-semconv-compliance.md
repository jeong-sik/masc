# RFC-OAS-003: OpenTelemetry GenAI Semantic Conventions Compliance

Status: Draft
Created: 2026-04-16
Author: (context: cascade boundary cleanup follow-up)
Reference spec: https://opentelemetry.io/docs/specs/semconv/gen-ai/

## 1. Summary

OAS emits OTel spans with a subset of GenAI semantic conventions. Several required and recommended attributes are missing, and one OAS-local extension (`gen_ai.turn`) is not part of the spec. This RFC proposes compliance without breaking existing consumers, using the `OTEL_SEMCONV_STABILITY_OPT_IN` dual-emission pattern that OTel itself uses for transition.

## 2. Current State

`lib/otel_tracer.ml:semantic_attrs` (origin/main @ 57c66359):

```ocaml
let semantic_attrs (attrs : Tracing.span_attrs) =
  [ ("gen_ai.agent.name", attrs.agent_name);
    ("gen_ai.turn", string_of_int attrs.turn);
    ("gen_ai.operation.name", attrs.name) ]
```

Metrics (`lib/metrics.mli`) do emit `gen_ai.client.token.usage` and `gen_ai.client.operation.duration` which are spec-compliant.

## 3. Gap Analysis

### 3.1 Required by spec, missing on spans

| Attribute | Purpose | Source |
|-----------|---------|--------|
| `gen_ai.request.model` | Model name as requested by the caller | `agent_state.config.model` or `Provider_config.model_id` |
| `gen_ai.system` | Provider name (openai/anthropic/ollama/...) | `Provider_config.kind` lowercased |
| `gen_ai.operation.name` | ✅ present but spec enum is `chat|text_completion|embeddings|...` — verify OAS passes `"chat"` not a custom name |

### 3.2 Recommended, missing on spans

| Attribute | Purpose | Source |
|-----------|---------|--------|
| `gen_ai.response.id` | Provider response id | `api_response.id` |
| `gen_ai.response.model` | Model name in response (may differ from request) | `api_response.model` |
| `gen_ai.response.finish_reasons` | Stop reasons as array | `api_response.stop_reason` |
| `gen_ai.usage.input_tokens` | Input token count on span (also emitted as metric) | `api_response.usage.input_tokens` |
| `gen_ai.usage.output_tokens` | Output token count on span | `api_response.usage.output_tokens` |
| `gen_ai.request.temperature` | Sampling temperature | `Provider_config.temperature` |
| `gen_ai.request.max_tokens` | Max output tokens | `Provider_config.max_tokens` |
| `gen_ai.request.top_p` | Top-p sampling | `Provider_config.top_p` |

### 3.3 OAS-specific non-standard

| Attribute | Notes |
|-----------|-------|
| `gen_ai.turn` | Turn counter inside a multi-turn loop. Not in OTel spec. Keep but rename to `oas.agent.turn` to avoid polluting the `gen_ai` namespace. |

## 4. Proposal

### 4.1 Extend `Tracing.span_attrs`

```ocaml
type span_attrs = {
  agent_name: string;
  turn: int;
  name: string;
  kind: span_kind;
  (* new fields, all optional so existing callers continue to work *)
  request_model: string option;
  response_id: string option;
  response_model: string option;
  finish_reasons: string list;     (* empty list == not set *)
  input_tokens: int option;
  output_tokens: int option;
  temperature: float option;
  max_tokens: int option;
  top_p: float option;
  system: string option;            (* gen_ai.system *)
}
```

### 4.2 `otel_tracer.semantic_attrs` rewrite

```ocaml
let opt_attr k v =
  match v with Some s -> [(k, s)] | None -> []

let semantic_attrs (attrs : Tracing.span_attrs) =
  [ ("gen_ai.agent.name", attrs.agent_name);
    ("oas.agent.turn", string_of_int attrs.turn);
    ("gen_ai.operation.name", attrs.name) ]
  @ opt_attr "gen_ai.system" attrs.system
  @ opt_attr "gen_ai.request.model" attrs.request_model
  @ opt_attr "gen_ai.response.id" attrs.response_id
  @ opt_attr "gen_ai.response.model" attrs.response_model
  @ (if attrs.finish_reasons = [] then []
     else [("gen_ai.response.finish_reasons",
            "[" ^ String.concat "," (List.map (Printf.sprintf "%S") attrs.finish_reasons) ^ "]")])
  @ opt_attr "gen_ai.usage.input_tokens" (Option.map string_of_int attrs.input_tokens)
  @ opt_attr "gen_ai.usage.output_tokens" (Option.map string_of_int attrs.output_tokens)
  @ opt_attr "gen_ai.request.temperature" (Option.map (Printf.sprintf "%g") attrs.temperature)
  @ opt_attr "gen_ai.request.max_tokens" (Option.map string_of_int attrs.max_tokens)
  @ opt_attr "gen_ai.request.top_p" (Option.map (Printf.sprintf "%g") attrs.top_p)
```

### 4.3 Migration: `OTEL_SEMCONV_STABILITY_OPT_IN`

OTel recommends dual emission during transition:

| Env value | Emitted attributes |
|-----------|-------------------|
| unset (default) | Legacy (`gen_ai.turn` in the old place) + new (`oas.agent.turn`) — dual |
| `gen_ai_latest` | New only (`oas.agent.turn`) |
| `gen_ai_legacy` | Legacy only (`gen_ai.turn` in the old place) |

After N releases, drop dual-emit and require `gen_ai_latest` implicitly.

### 4.4 Populating new fields

- `api_openai.ml`, `api_anthropic.ml`, `api.ml`: enrich the `span_attrs` passed to `Tracer.start_span` with `request_model`, `system`, and on response, `response_id/model/finish_reasons/usage.*`.
- `pipeline.ml`: pipe through `temperature`/`max_tokens`/`top_p` from `Provider_config` or agent state.

## 5. Breaking changes

- `Tracing.span_attrs` gains 10 optional fields. Callers constructing the record literal must set them. Most callers use a helper (`Tracer.start_span`) that already owns this construction, so downstream impact is bounded.
- `gen_ai.turn` removed from spans (moved to `oas.agent.turn`); dashboards filtering on the old attribute break unless they run in dual-emit mode.

## 6. Test plan

- Unit tests: `test_otel.ml` assertions for each new attribute when the optional field is Some, and for *absence* when None. Add dual-emit mode assertions.
- Integration: replay a recorded chat turn through the API layer and assert the emitted OTLP JSON contains all required + recommended attributes.
- Compliance: add a test that checks every listed attribute name matches the OTel spec exactly (catches typos).

## 7. Out of scope

- `gen_ai.prompt` / `gen_ai.completion` (full message capture). Requires a log/event pipeline separate from span attributes and raises PII concerns. Separate RFC.
- `server.address` / `server.port` on spans. Inherited from HTTP semconv when present via the HTTP client layer — OAS should not duplicate.
- Vector DB conventions (`db.system = "chroma"` etc.). OAS has no vector DB integration today.

## 8. Risks

- Attribute cardinality growth: new fields push OTel backends harder. Keep string encoding compact (no JSON blobs on spans).
- `gen_ai.response.finish_reasons` is documented as an array attribute. OAS `(string * string) list` encoding stringifies it; verify target backend (Datadog, Grafana Tempo, Honeycomb) accepts this shape.
- `OTEL_SEMCONV_STABILITY_OPT_IN` reads env at every span start; consider caching.

## 9. References

- [OTel GenAI semantic conventions (main index)](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [GenAI span attributes](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/)
- [GenAI metrics](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-metrics/)
- [Datadog adoption note (v1.37)](https://opentelemetry.io/blog/2024/otel-generative-ai/)
- OAS RFC-002 (metric naming) — same observability track, this RFC extends it to spans.

## 10. Decision log entry (when accepted)

- Decided: migrate to OTel GenAI semconv compliance in two stages.
- Stage 1 (this RFC): extend span_attrs, emit required + recommended attributes, dual-emit legacy `gen_ai.turn` for one release cycle.
- Stage 2 (follow-up): remove dual emit, add `gen_ai.prompt`/`gen_ai.completion` log events with explicit opt-in + PII-stripping hooks.
