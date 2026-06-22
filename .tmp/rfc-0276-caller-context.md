# RFC-0276 caller context

Companion evidence for RFC-0276 (purge the keeper social-model self-report
protocol, Phase 2 of RFC-0275). Records the premise verification, the
blast-radius survey, the four adversarial refutations (wf_7fc10231), and the
orphan-test investigation so a reviewer can confirm the classification without
re-deriving it.

## Premise verification — the protocol is LIVE, not dormant scaffolding

The 9-agent blast-radius survey first concluded request-help routing was
"dormant scaffolding, zero product loss." Direct reading of the prompt file
falsified this:

```
config/prompts/keeper.unified.system.md:113   "report the concrete blocker (SPEECH_ACT: request_help)"
config/prompts/keeper.unified.system.md:147   "If blocked, set SPEECH_ACT: request_help"
config/prompts/keeper.unified.system.md:148   "If nothing meaningful to do, set SPEECH_ACT: stay_silent and DELIVERY_SURFACE: silent"
config/prompts/keeper.unified.system.md:158-165  "Start every response with machine-readable headers: SOCIAL_MODEL/BLOCKER/NEED/SPEECH_ACT/DELIVERY_SURFACE"
config/prompts/keeper.core_behavior.md:4      references stay_silent/silent for no-work turns
```

The prompt actively instructs every keeper to emit the headers every turn. The
RFC therefore treats removal as a justified **behavior change**, not a no-op
cleanup (RFC §2.4).

## The runtime re-derives what the header self-declares (the duplication)

```
lib/keeper/social_model/keeper_social_model_bdi_speech_v1.ml:235-276  transition: derives surface from tool names + text
lib/keeper/social_model/keeper_social_model_bdi_speech_v1.ml:239      tool-only path overrides the self-declared header when tools present
lib/keeper/social_model/keeper_social_model_bdi_speech_v1.ml:133-168  social_state_of_headers: parses DELIVERY_SURFACE header (the C1 divergence source)
```

The header layer complects self-reported intent with observable fact. The
runtime already measures the fact; the self-report adds only the rare divergence
exploited in C1.

## Adversarial verification (wf_7fc10231, 2026-06-22)

Four load-bearing claims, each refuted-by-default by an independent skeptic
agent reading the code.

### C1 — "decouple is byte-exact" → REFUTED → reframed as documented behavior change

```
lib/keeper/keeper_unified_turn_success.ml:88-93   surface_requires_evidence matches social_state.delivery_surface
lib/keeper/keeper_no_progress_loop_detector.ml:55  engine already primitive-bool: turn_made_progress ~strong_evidence ~surface_requires_evidence
```

A toolless turn that self-declares `DELIVERY_SURFACE: board_post` via the header
yields `requires_evidence=true`; a header-less identical turn infers
`Visible_reply` → `false`. Removing the header protocol eliminates the divergence
source, so the post-purge mapping (RFC §3.2 `turn_delivery`) is the correct
parse-don't-validate behavior, not a regression. Pinned by unit test (RFC §7).

### C2 — "reply-suppression no-op" → no chat/board sink confirmed; one residue flagged

```
lib/keeper/social_model/keeper_social_model_bdi_speech_v1.ml:283-303  apply_output_to_result: response_text="" suppression arms
lib/keeper/keeper_unified_metrics_result.ml:184  select_proactive_preview gated on is_visible_reply (RFC-0232)
lib/keeper/keeper_unified_metrics_decision.ml:223-226  writes "response_requests_confirmation" to decision JSON
```

No autonomous path appends `response_text` to a chat/board sink; the dashboard
preview is independently gated by RFC-0232 `Keeper_turn_outcome.is_visible_reply`.
Lone residue: `response_requests_confirmation` written to decision JSONL with no
live reader found — RFC §6 flags it for Phase-2b confirmation.

### C3 — "blocker_class independent of social_model" → HOLDS

```
lib/keeper/keeper_status_bridge_blocker.ml  blocker_class_of_sdk_error: typed, from SDK errors
lib/keeper/keeper_unified_metrics_failure.ml:178  social_state.blocker only an optional detail with public_reason fallback
```

The genuine "blocked" signal is the typed `blocker_class` consumed by
operator/dashboard/governance/fleet with no `speech_act` dependency. Removing the
request-help board auto-post is safe; the structured `[masc_oas_error]`
non-truncation rule (#9933) is folded into the `blocker_class` detail path
(RFC §3.3).

### C4 — "persistence tolerates removal" → JSON yes, TOML must delete validation

```
lib/keeper/keeper_meta_json_parse.ml  Safe_ops.json_string defaults tolerate unknown/missing keys
lib/keeper/keeper_types_profile_toml_parser.ml:48-66  social_model validation: returns Error for unknown values
lib/keeper/keeper_types_profile_toml_parser.ml:182  social_model field read
lib/keeper/keeper_types_profile_toml_normalizers.ml:27-36  normalize_social_model_opt / valid_social_model_strings
```

Old JSON checkpoints carrying social_model fields load clean (additive-ignore).
But the TOML parser actively validates `social_model` and rejects unknown values
(e.g. `experimental_v99`) — so removal is NOT "ignore the key"; the validation
block, the field read, and the normalizer must be deleted. An old config that
sets `social_model` then warns (unknown-key path), not fails (RFC §5).

## Orphan-test investigation (papering-over avoided)

Both the survey and the C4 skeptic claimed Phase 1 (#22023) should have failed
CI because `test/test_keeper_toml.ml` still contains `magentic_ledger_v1`. Chased
the contradiction instead of dismissing it:

```
$ rg -n magentic_ledger_v1 test/test_keeper_toml.ml          # 3 hits (:460,:480,:1161)
$ rg -n magentic_ledger_v1 test/test_keeper_toml_parser.ml   # 0 hits
```

CI runs `test_keeper_toml_parser.exe`. The `.inc` dune stanzas exist only for
`_parser`/`_loader`; there is no `test_keeper_toml.inc`. `test_keeper_toml.ml` is
an **orphan** — not wired into any dune stanza, never built, never run. Phase 1's
green CI is correct; the magentic refs are dead. RFC §3.1 schedules deleting or
wiring the orphan in Phase 2c.

Lesson: "a test file references X" ≠ "that test is built and run." With several
same-prefix `.ml` files, confirm live via the dune `.inc` stanza.

## Cross-references

- RFC-0275 (Phase 1, BDI triple + magentic_ledger_v1): PR #22023, CI green.
- RFC-0232 Keeper_turn_outcome (is_visible_reply): the independent visible-reply gate.
- RFC-0239 / RFC-0242: no-progress control flow re-grounded from delivery_surface to §3.2 turn_delivery.
