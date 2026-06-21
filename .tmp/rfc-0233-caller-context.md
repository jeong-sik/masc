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
