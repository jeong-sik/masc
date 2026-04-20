# Keeper social_state bounded invariant

Status: contract + post-mortem (Gen3 → Gen15)

See also:

- `docs/design/keeper-social-model-inventory.md`
- `docs/design/keeper-social-model-fsm.md`
- `specs/social-state-cap/SocialStateCap.tla`

## Contract

For every speech model in `Keeper_social_model_registry` and for every
way a `Types.social_state` can enter `meta.runtime` (live turn or disk
checkpoint), the emitted or restored value must satisfy:

```
|belief_summary|                                <= 400 + ε
|active_desire| |current_intention|
|blocker|       |need|                          <= 200 + ε
```

ε is the single "…" ellipsis appended by `truncate_string`. Enum
fields (`speech_act`, `delivery_surface`, `social_model`) pass through
unchanged.

The budget constants live in `Keeper_social_model_types`:

- `default_belief_summary_max_chars = 400`
- `default_option_field_max_chars   = 200`

Both are labeled-optional arguments on `cap_social_state`, so a
cascade-level policy module can override them per speech model
without touching any emission call site.

## Why the bound exists

### Observation

`apply_output_to_result` in `keeper_social_model_bdi_speech_v1.ml`
routes `Stay_silent` by clearing `response_text` but returning
`social_state` unchanged. The caller persists that state as
`previous_state`, and the next turn's `transition` reads the full
`belief_summary` / option fields as context. Without a cap, a keeper
that repeats `stay_silent` keeps accumulating narrative into those
fields — the BDI envelope length is not tied to speech surface
visibility.

Empirical trigger was a keeper whose `BELIEF_SUMMARY` carried multi-
paragraph "20 가지 증명 완료" self-citation while
`SPEECH_ACT: stay_silent` and `DELIVERY_SURFACE: silent`.

### Prior-art channels

| Generation | PR | Channel | Primitive |
| --- | --- | --- | --- |
| Gen3 | #7647 | prompt injection (backward-looking strip) | `filter_forward_looking_summary` |
| Gen4 | #7668 | OAS compaction (`[STATE]` scrub) | `Keeper_summarizer` |
| Gen7 | #7676 | `keeper_state_snapshot` persistence cap | `cap_snapshot` |
| Gen8 | #7692 | `social_state` write side (BDI v1) | `cap_social_state` |
| Gen12 | #7704 | checkpoint JSON load | `truncate_string` |
| Gen13 | #7709 | Magentic ledger v1 overlay | `cap_social_state` |
| Gen15 | #7721 | formal spec + TLC clean/buggy cfgs | `SocialStateCap.tla` |

Gen3/4/7 sit on the consumption path that ends at the LLM prompt.
Gen8/12/13 sit on the persistence path that ends in `meta.runtime`
or `decision_audit`. The two paths are independent — a leak on either
side re-seeds bloat on the other.

## Single plug point

Every cap application resolves to one of three primitives:

- `Keeper_memory_policy.cap_snapshot` — snapshot-size cap (Gen7)
- `Keeper_social_model_types.cap_social_state` — narrative-record cap (Gen8, Gen13)
- `Keeper_social_model_types.truncate_string` — scalar cap (Gen12 load side)

A new speech model is expected to wrap its final emission with
`cap_social_state` (one line at the return point) and nothing else.
A new persistence schema is expected to route every string field
through `truncate_string` on load. Both primitives are idempotent:
double-capping is a noop.

## Verification layers

- **Unit tests** — `test_social_state_cap` (6), `test_social_state_cap_on_load` (5), `test_magentic_ledger_cap` (4), `test_snapshot_size_cap` (6)
- **TLA+ model check** — `specs/social-state-cap/SocialStateCap.{tla,cfg,-buggy.cfg}` with `CapHolds` invariant
  - Clean: 11,665 distinct states, no violation
  - Buggy (cap option fields skipped): `CapHolds` violated after 113 distinct states — proves the invariant has teeth

## Adding a new speech model

1. Import `Keeper_social_model_types`.
2. At the end of `apply_to_result` / `derive_failure_state`, wrap the
   returned `social_state` with `Types.cap_social_state`.
3. Add a test mirroring `test_magentic_ledger_cap.ml`.
4. Re-run `scripts/tla-check.sh` (or `make -C specs check-all`) — the
   spec does not
   need to be amended, but the spec should continue to pass because
   the new model behaves like `EmitClean`.

If a model legitimately needs a larger budget (e.g. it carries a
structured ledger and 400 chars is too tight), override at the call
site:

```ocaml
Types.cap_social_state
  ~belief_max_chars:1200
  ~option_max_chars:400
  state
```

Do not duplicate `truncate_string` in the model module — reuse the
primitive so the TLA+ spec keeps matching the code.

## Non-goals

- This contract does not prevent the LLM from *producing* long
  narrative. It prevents that narrative from accumulating across
  turns inside the keeper runtime. The prompt-side caps (Gen3/4/7)
  remain responsible for the consumption side.
- This contract does not cap **tool-call arguments** or **decision
  audit JSON**. Those surfaces have their own budgets elsewhere.
