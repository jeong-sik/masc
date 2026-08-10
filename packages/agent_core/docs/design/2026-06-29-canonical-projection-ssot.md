# Canonical Projection SSOT — OAS should own the serialization of its own ADTs

- Date: 2026-06-29
- Status: in progress (F1 landed; F2–F14 are follow-ups)
- Motivating PR: `refactor(stop-reason): single SSOT for stop_reason wire serialization`

## Problem

OAS defines the core ADTs (`stop_reason`, `api_usage`, `content_block`,
`inference_telemetry`, `provider_kind`, `capabilities`) but does not always
expose the *canonical projection* of those types — `to_string`, `to_label`,
`summarize`, `sanitize`, `total_tokens`. When the projection is missing,
consumers (including OAS's own modules) re-spell it locally, and the copies
drift.

This is an OAS-internal defect first. The clearest proof needs no external
consumer: `stop_reason -> string` was re-implemented in four OAS modules with
**divergent output**:

| variant | `agent.ml` (label) | `agent_tool.ml` | `cache.ml` | `response_shape.ml` (diag) |
|---|---|---|---|---|
| `StopToolUse` | `stop_tool_use` | `tool_use` | `tool_use` | `tool_use` |
| `ContextWindowExceeded` | `model_context_window_exceeded` | `model_context_window_exceeded` | `model_context_window_exceeded` | `context_window_exceeded` |
| `Unknown s` | `"unknown:" ^ s` | `s` | `s` | `unknown(%S)` |

Meanwhile `Types.stop_reason_of_string` (the decoder) defines the *real*
canonical vocabulary, so three of the four `to_string` copies were silently
"correct" and one (`agent.ml`) was not round-trippable.

The same shape repeats for other ADTs — see the follow-up table.

## Principle

> The canonical projection of a type lives next to the type. `to_string` sits
> beside `of_string`; `summarize` sits beside `content_block`.

Two distinct projections are often needed and must be named separately:

- **wire / round-trip** (`stop_reason_to_string`): exact inverse of the decoder.
  Used for serialization, cache keys, API output. Round-trippable.
- **metric label** (`stop_reason_to_metric_label`): stable, low-cardinality.
  `Unknown _ -> "unknown"` so provider-supplied raw strings cannot explode
  metric-label cardinality.

Collapsing these two into one string type is what produced the drift.

## Boundary note (MASC)

OAS must never reference MASC; this initiative does not change that. MASC is one
downstream consumer that *also* re-implements these projections
(`keeper_hooks_oas_types.stop_reason_to_label`,
`keeper_event_bridge_error_json.stop_reason_to_wire`, `inference_utils.zero_usage`,
`summarize_thinking_blocks`, …). Every projection OAS exposes lets a MASC copy be
deleted in favor of `Agent_sdk.*` — the dependency direction stays MASC→OAS.
What stays in MASC is policy: identity redaction, Otel label keys, per-keeper
routing headers, cost-ledger and operator-alert routing.

## F1 — `stop_reason` (landed)

- `Types.stop_reason_to_string` (inverse of `stop_reason_of_string`) +
  `Types.stop_reason_to_metric_label` (stable). Explicit constructor list, no
  wildcard, so a new variant fails to compile until handled.
- Byte-identical copies in `agent_tool.ml` and `cache.ml` delegate to the SSOT
  (zero behavior change; cache `schema_version` "1" preserved).
- `test/test_stop_reason_ssot.ml` pins the canonical strings + round-trip.
- **Deferred on purpose**: `agent.ml` (metric label, `stop_tool_use` /
  `unknown:`+s) and `response_shape.ml` (operator diagnostic,
  `context_window_exceeded` / `unknown(%S)`) emit different strings. Migrating
  them changes telemetry / diagnostic output — a behavior change that needs
  consumer analysis, not a silent unify. Tracked separately in #2241.

## Follow-up projections to expose (roadmap)

| # | ADT / concern | Add to OAS | Drops these duplicates |
|---|---|---|---|
| F2 | `content_block` thinking summary | `Response_shape.summarize_blocks : content_block list -> t` | MASC `summarize_thinking_blocks` |
| F3 | `content_block`/`message` UTF-8 sanitize | `Utf8_sanitize.sanitize_message(s)` | MASC `inference_utils.sanitize_*_utf8` |
| F4 | `api_usage` zero | use existing `Types.zero_api_usage` | MASC `zero_usage` ×2 |
| F5 | `Capabilities.capabilities` ↔ `Provider.capabilities` | transparent alias or `to_provider_capabilities` | MASC `agent_capabilities_of_llm_capabilities` 35-field copy |
| F6 | `provider_kind -> request_kind` | `Provider_config.request_kind_of_provider_kind` | MASC `request_kind_of_provider_cfg` |
| F7 | per-kind non-auth headers | `Api_common.non_auth_headers_for_kind` (anthropic-version) | MASC `default_headers_for_kind` ×2 (self-flagged "keep in sync") |
| F9 | `api_usage` sanity validation | `usage_validation.classify` | MASC `keeper_usage_trust.classify` (keep `warns_operator`) |
| F10 | JSON-schema `required`/`properties` extraction | `Mcp_schema.{required,property}_names_of_schema` | MASC `tool_input_validation.{required_names,schema_property_names}` (keep oneOf/additionalProperties + diagnostics) |
| F11 | wall tok/s from `inference_telemetry` | `usage_projection.wall_tokens_per_second` | MASC `wall_tokens_per_second` |
| F12 | `api_usage` total | `Types.total_tokens` | MASC `total_tokens` ×2 |
| F13 | misc usage/telemetry/cost helpers | `Types`/`pricing` helpers | MASC `keeper_hooks_oas_types.{usage_has_tokens,context_max_of_telemetry,oas_reported_cost}` |
| F14 | `stop_reason` metric/diagnostic migration | consumer analysis for `agent.ml` labels and `response_shape.ml` diagnostics (#2241) | legacy OAS-local `stop_reason` string variants, if migration is safe |

Sequencing: F4/F12 (trivial) → F5/F6/F7 (OAS-internal, immediate value) →
F2/F3 (content_block utils) → F9/F10/F11/F13/F14.

Rule for every step: OAS exposes a generic util; consumers call it. Never the
reverse.

## Not in scope (intentionally)

- telemetry-as-fix counters in MASC (timeout/usage-anomaly counters) — those are
  alert signals over OAS-side gaps, a different class, not boundary violations.
- MASC policy that must stay MASC: identity redaction, Otel label keys,
  per-keeper routing, cost ledger, operator alert routing.
