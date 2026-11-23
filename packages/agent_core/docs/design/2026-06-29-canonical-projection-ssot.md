# Canonical Projection SSOT — agent_core should own the serialization of its own ADTs

- Date: 2026-06-29
- Status: in progress (F1, F2, F4 and F12 landed; the other rows are follow-ups)
- Motivating PR: `refactor(stop-reason): single SSOT for stop_reason wire serialization`

## Problem

agent_core defines the core ADTs (`stop_reason`, `api_usage`, `content_block`,
`inference_telemetry`, `provider_kind`, `capabilities`) but does not always
expose the *canonical projection* of those types — `to_string`, `to_label`,
`summarize`, `sanitize`, `total_tokens`. When the projection is missing,
consumers (including agent_core's own modules) re-spell it locally, and the copies
drift.

The follow-up table lists the projections that are still re-spelled.

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

agent_core must never reference MASC; this initiative does not change that. MASC is one
downstream consumer that *also* re-implements some of these projections (see
the follow-up table). Every projection agent_core exposes lets a MASC copy be
deleted in favor of `Agent_core.*` — the dependency direction stays MASC→agent_core.
What stays in MASC is policy: identity redaction, Otel label keys, per-keeper
routing headers, cost-ledger and operator-alert routing.

## F1 — `stop_reason` (landed)

- `Types.stop_reason_to_string` (inverse of `stop_reason_of_string`) +
  `Types.stop_reason_to_metric_label` (stable). Explicit constructor list, no
  wildcard, so a new variant fails to compile until handled.
- `agent.ml` and `cache.ml` call the SSOT.
- `test/test_stop_reason_ssot.ml` pins the canonical strings + round-trip.
- `Response_shape.stop_reason_diagnostic_string` delegates to the SSOT for every
  constructor except `Unknown raw`, which it prints as `unknown(%S)` for
  operator diagnostics.

## Follow-up projections to expose (roadmap)

| # | ADT / concern | Add to agent_core | Drops these duplicates |
|---|---|---|---|
| F2 (landed) | `content_block` thinking summary | `Response_shape.summarize_blocks : content_block list -> t` | MASC `summarize_thinking_blocks` |
| F3 | `content_block`/`message` UTF-8 sanitize | `Utf8_sanitize.sanitize_message(s)` | MASC `inference_utils.sanitize_*_utf8` |
| F4 (landed) | `api_usage` zero | use existing `Types.zero_api_usage` | MASC `zero_usage` ×2 |
| F7 | per-kind non-auth headers | `Api_common.non_auth_headers_for_kind` (anthropic-version) | MASC `Runtime_provider_binding.default_headers_for_kind` |
| F9 | `api_usage` sanity validation | `usage_validation.classify` | MASC `keeper_usage_trust.classify` (keep `warns_operator`) |
| F10 | JSON-schema `required`/`properties` extraction | `Mcp_schema.{required,property}_names_of_schema` | MASC `tool_input_contract.{required_names,schema_property_names}` (keep oneOf/additionalProperties + diagnostics) |
| F11 | wall tok/s from `inference_telemetry` | `usage_projection.wall_tokens_per_second` | MASC `wall_tokens_per_second` |
| F12 (landed) | `api_usage` total | `Types.total_tokens` | MASC `total_tokens` ×2 |
| F13 | misc usage/telemetry/cost helpers | `Types`/`pricing` helpers | MASC `keeper_hooks_agent_core_types.{usage_has_tokens,context_max_of_telemetry,agent_core_reported_cost}` |

Sequencing for the open rows: F7 (agent_core-internal, immediate value) →
F3 (content_block utils) → F9/F10/F11/F13.

Rule for every step: agent_core exposes a generic util; consumers call it. Never the
reverse.

## Not in scope (intentionally)

- telemetry-as-fix counters in MASC (timeout/usage-anomaly counters) — those are
  alert signals over agent_core-side gaps, a different class, not boundary violations.
- MASC policy that must stay MASC: identity redaction, Otel label keys,
  per-keeper routing, cost ledger, operator alert routing.
