# RFC-0233 Caller Context (§8 Amendment)

Owner request, 2026-06-21 (keeper-turn observability `/goal`):

- The keeper-turn inspector's token-economy panel fabricated two values:
  a hardcoded 200K context window and hardcoded Claude $3/$15 pricing,
  applied to every runtime. For a non-Claude runtime (e.g.
  `glm-coding.glm-5-turbo`) the ctx-fill% and cost were therefore wrong.
- Token counts were already real (`usage.input_tokens`/`output_tokens`); only
  the window denominator and the price rates were fabricated constants.
- Ground the panel in real runtime facts, or render honest absence — never a
  fabricated value.

Design constraints:

- `context_window` + `price_input_per_million`/`price_output_per_million` are
  added as `option` fields on `Turn_record.t`; `None` renders "미상" (unknown),
  consistent with the existing `model`/`finish_reason` absence contract (§2.3).
- Source real facts from the runtime binding MASC already retains at boot
  (`Runtime.t.binding.price_input`/`price_output`, runtime.ml:19) via a sibling
  projection `Runtime.pricing_of_runtime_id`; `context_window` is the
  keeper-resolved `max_context` already in scope at the write site.
- No OAS change: price is an operator-config concern; OAS's
  `Provider_runtime_binding` catalog omits price by design and is untouched.
- Cost is derived in the view (real price × real tokens), not stored as a
  precomputed number — views-derive (§2.3).
- `context_window` is the keeper compaction budget, not the Ollama-only
  `num_ctx` transport cap (documented caveat, §8.4).

Verification expectation:

- The amended RFC passes the local rfc-enforcer (R1–R5, including this
  caller-context file).
- `test_turn_record.ml` proves the three new fields round-trip and that the
  absent case omits the keys / decodes `None`.
- The dashboard inspector renders "미상" when the fields are absent and a
  real `%` / `$` when present.

## §9 Amendment (2026-06-22) — response-generation phase duration

Caller context for the `request_latency_ms` field added under §9.

Owner request, 2026-06-22 (same keeper-turn observability `/goal`):

- The phase waterfall's `gen` (response-generation) phase showed "측정 없음"
  on every turn; its own `meta` declared "provider/OAS duration is not
  recorded in turn-records".
- The provider call wall-clock was already measured — OAS
  `inference_telemetry.request_latency_ms`, synthesized by the transport
  layer for every provider — and already retained on the keeper turn result
  (`keeper_agent_result.ml:63`, source `result.response.telemetry`). The
  record simply never stored it.

Design constraints:

- One `option` field `request_latency_ms : int` on `Turn_record.t`. Both
  `inference_telemetry` and the field itself are `option`, so the write site
  uses `Option.bind` (not `Option.map`) to avoid nesting option-of-option.
  `None` on the error path renders "측정 없음", never a fabricated 0.
- The `gen` phase maps `request_latency_ms` to `durationMs` with a new
  `durationSource` variant `'provider_telemetry'` (distinct from
  `'tool_call_log'` so the tooltip names the real source). `ctx`/`reason`
  stay `'not_recorded'`: OAS has no isolated measurement for those phases.
- No OAS change: MASC consumes a public OAS response field, the same pattern
  as `keeper_hooks_oas.ml:417` (`Option.value ~default:0 t.request_latency_ms`
  — but that default-0 is for a tok/s log line, not a stored record).
- No phase-level split (`prefill_ms`/`ttfrc_ms`/`timings`): provider-native,
  mostly `None` across the cloud keeper fleet — a Wave-2c candidate.

Verification expectation:

- `test_turn_record.ml` proves `request_latency_ms` round-trips and that the
  absent case omits the key / decodes `None`.
- The inspector renders a real `formatMsCompact` on the `gen` phase when
  present, "측정 없음" when absent.
