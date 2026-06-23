# RFC-0282: De-structure keeper self_model (will/needs/desires) into general persona description

- Status: Draft
- Author: vincent (+ Claude Opus 4.8)
- Created: 2026-06-22
- Supersedes scope: completes the BDI excision line of RFC-0275 / RFC-0276
- Implementation PRs: (this RFC's PR)

## 1. Summary

Remove the structured `will` / `needs` / `desires` fields — the keeper "self_model" BDI-state triple — from the keeper persona. The persona content survives: it is already expressed (and largely duplicated) in the keeper's `role` / `trait` / `goal` horizons / `instructions` prose. Any non-redundant content (chiefly `needs`, the input-requirement list) is folded into the keeper's `instructions` description before deletion. No keeper loses persona information; the model still conditions on the same disposition, just as ordinary description text rather than as a labeled `Will:` / `Needs:` / `Desires:` state block.

## 2. Motivation

### 2.1 The BDI-state framing is the thing being removed, not the content

RFC-0275 and RFC-0276 already purged the **social_model** — the keeper's self-*report* header (`speech_act` / `delivery_surface` / `social_state` + the belief/desire/intention triple) — because it was an unmeasured, behavior-distorting feedback signal. `self_model` (`will` / `needs` / `desires`) is the *other* BDI-flavored surface those RFCs explicitly left untouched (RFC-0276 §4 Phase 2c: "the persona `KeeperBDIPanel` (will/needs/desires self-model) is a separate live feature, untouched").

The remaining objection is structural, not about worth: a keeper's persona should be a **description**, not a tracked cognitive **state**. Modeling `will` / `needs` / `desires` as three typed fields complects (Hickey, *Simple Made Easy*) two concerns — persona-as-prose and persona-as-BDI-state — and the BDI-state half is redundant.

### 2.2 The content is already duplicated as prose (evidence)

`config/personas/<keeper>/profile.json` already carries a rich persona narrative in `role`, `trait`, the four `goal` horizons, and `instructions`. The `will` / `needs` / `desires` fields restate it:

| keeper | `will` (disposition) | already in | `desires` (end-state) | already in |
|---|---|---|---|---|
| issue_king | "이슈를 보고 참지 못하고…" | `role`/`trait`/`instructions` | "모든 이슈가 closed…" | `goal`/`long_goal` |
| taskmaster | "미처리 task를 보고 참지 못하고…" | `role`/`instructions` | "모든 task가 claimed…" | `goal` |
| verifier | "completion notes를 신뢰하지 않는다…" | `instructions` (2580 chars) | "정량 기준의 100% 실측…" | `goal` |

`needs` (input-requirement list, e.g. issue_king "GitHub 이슈 URL, PR 번호, reproduce 조건, 머지 블록커 목록") is the only field with consistently distinct operational content; it is folded into `instructions` per keeper.

The same triple is **duplicated across two config formats**: `config/keepers/*.toml` *and* `config/personas/*/profile.json` (`keeper.*`). Both parse into the same `keeper_profile_defaults`. Two write sites for one redundant concept is itself a maintenance liability.

### 2.3 Honest accounting: this is load-bearing, hence content-preserving (not blind deletion)

`will`/`needs`/`desires` are **injected verbatim into the keeper LLM system prompt every turn**, via two paths:

- `keeper_unified_prompt.ml:652-668` (`build_prompt`) renders `line_block "Will"/"Needs"/"Desires"`; the result is the live per-turn `system_prompt` at `keeper_unified_turn.ml:287-326`.
- `keeper_prompt.ml:354-361` (`build_keeper_system_prompt`) appends `"Will: "^will`, `"Needs: "^needs`, `"Desires: "^desires` into the `<identity>` block.

No control/decision logic branches on the *content* of these fields — the only field-level conditionals are empty-string rendering (`keeper_prompt.ml:233-241`), byte-cap truncation (`keeper_personality_io.ml:69-91`), and string-equality config-drift detection (`keeper_personality_io.ml:122-134`). All serve the prompt/display pipeline.

Because deletion removes labeled lines the model conditions on, this is a **behavior change**, and its behavioral magnitude is **unmeasured** (no eval asserts on will/needs/desires outcomes — every existing test covers parsing, byte-caps, overlay merge, drift, or WARN messages). The mitigation is content preservation: the persona disposition is retained in `role`/`trait`/`goal`/`instructions`, so the prompt still carries the same information, only de-labeled and de-structured.

## 3. Non-goals (explicitly preserved)

- **Goal horizons** (`goal` / `short_goal` / `mid_goal` / `long_goal`) — a separate live concern, kept.
- **`persona_name`, `role`, `trait`, `instructions`** — the prose persona; kept (and the fold target).
- **`persona_extended` / `<persona>` block** (`config/personas/<name>/AGENT.md`) — kept.
- **`meta_cognition` `collective_desires`** (`meta_cognition_snapshot.ml:495`) — a workspace-level aggregate, NOT the keeper persona field; must not be conflated.
- **Goals/deliberation (RFC-0034/0252), turn_delivery (RFC-0276 §3.2)** — untouched.

## 4. Surface inventory

| path | role | disposition |
|---|---|---|
| `config/keepers/*.toml` (7) | `will`/`needs`/`desires` lines | delete (fold `needs` → `instructions`) |
| `config/personas/*/profile.json` (6) | `keeper.will`/`needs`/`desires` | delete (fold `needs` → `keeper.instructions`) |
| `lib/keeper/keeper_meta_contract.ml` | `keeper_meta.{will,needs,desires}` (489-491), `apply_profile_default` (622-624) | delete fields |
| `lib/keeper/keeper_types_profile.ml` | `keeper_profile_defaults.{will,needs,desires}` + overlay (357-359) | delete fields |
| `lib/keeper/keeper_types_profile_toml_parser.ml` | `str "will"/"needs"/"desires"` (133-135), key lists (183-185, 224-226) | delete |
| `lib/keeper/keeper_types_profile_persona_defaults.ml` | `json_string_opt "will"/"needs"/"desires"` (50-52) | delete |
| `lib/keeper/keeper_personality_io.ml` | `raw_personality.{will,needs,desires}` + `to_prompt_form` + byte-cap/drift | delete fields / simplify |
| `lib/keeper/keeper_prompt.ml` | `build_keeper_system_prompt ~will ~needs ~desires` (203-205), render (239-241, 354-361) | delete params + render |
| `lib/keeper/keeper_unified_prompt.ml` | `build_prompt` will/needs/desires trait_lines (652-668) | delete render |
| `lib/keeper/keeper_run_context.ml` | pass-through (154-156) | delete |
| `lib/keeper/keeper_turn_up_create.ml` | pass-through (341-353), persisted meta JSON (555-557) | delete |
| `lib/keeper/keeper_tool_persona_runtime.ml` | `parse_self_model_opt` + persona-set tool (366-379) | delete / retarget to instructions |
| `lib/config/env_config_core.ml` | `keeper_will/needs/desires` getters (520-530), `MASC_KEEPER_WILL/NEEDS/DESIRES` | delete |
| `docs/runtime-tunables.md` | catalog entries (39-41) | regen (autogen) |
| `lib/dashboard/dashboard_http_keeper.ml` | serialize will/needs/desires (955-967) | delete |
| `lib/keeper/keeper_status_bridge.ml` | status fields (92-102) | delete |
| `lib/dashboard/dashboard_http_keeper_snapshot.ml` | prompt preview will/needs/desires (57-59, 144) | delete |
| `dashboard/src/components/.../keeper-bdi-panel.ts` (+ consumers) | render will/needs/desires | delete / retarget |
| `test/test_keeper_personality_io_validate.ml`, `test_keeper_toml.ml`, `test_keeper_prompt_personality_field_aggregation.ml`, `test_keeper_effective_meta_overlay.ml`, `test_keeper_profile_normalize_10552.ml`, … | field assertions | remove/update |

## 5. Migration design

1. **Config (content-preserving first).** For each keeper: fold the `needs` content (and any `will`/`desires` nuance not already present) into the keeper's `instructions` prose, then delete the three structured fields from *both* `*.toml` and `profile.json`. Per-keeper fold recorded in the PR.
2. **Types + parsers (compiler-driven).** Remove the fields from `keeper_meta`, `keeper_profile_defaults`, and both parsers. The OCaml compiler then enumerates every consumer — no `_` catch-all is added; each error site is resolved explicitly.
3. **Prompt assembly.** Remove the `Will:`/`Needs:`/`Desires:` render blocks and the `~will ~needs ~desires` parameters. The `<identity>` block keeps `Goal` horizons + `Custom instructions`.
4. **Env knobs + catalog.** Delete `MASC_KEEPER_WILL/NEEDS/DESIRES` getters; regenerate `docs/runtime-tunables.md`.
5. **Dashboard.** Remove the will/needs/desires render + backend serializers; TS compiler drives the type/union removal.
6. **Tests.** Delete field-specific tests; update overlay/parse tests to the reduced shape.

## 6. Acceptance criteria

- `rg '\bwill\b|\bneeds\b|\bdesires\b' lib/keeper/keeper_meta_contract.ml lib/keeper/keeper_prompt.ml lib/keeper/keeper_unified_prompt.ml` → 0 hits for the persona fields (goal-horizon `needs`-free).
- `rg 'MASC_KEEPER_WILL|MASC_KEEPER_NEEDS|MASC_KEEPER_DESIRES' lib/ docs/` → 0.
- `rg '"will"|"needs"|"desires"' config/keepers/ config/personas/*/profile.json` → 0 (persona triple).
- `dune build @check --root .` green; affected OCaml tests pass; `ocamlformat --check` clean.
- `tsc --noEmit` 0; `vitest run` pass; `eslint` 0.
- Each migrated keeper's effective `instructions` retains its prior `needs` content (manual diff in PR).

## 7. Risks

- **Behavior change (acknowledged, §2.3):** prompt text changes (labels removed; `needs` folded into prose). Magnitude unmeasured. Mitigation: content preserved in `instructions`/`role`/`trait`/`goal`; reversible via git.
- **Drift-detection removal:** `keeper_personality_io` byte-cap/drift logic for these fields is removed; if other fields still need it the shared helper is preserved, only the will/needs/desires arms drop.
- **Persisted meta JSON:** older session snapshots may contain will/needs/desires keys; the reader must ignore unknown keys (verify `keeper_turn_up_create.ml` deserialize tolerates absence — it reads named fields, so dropped keys are simply not read).

## 8. Rollout

Single PR (the config fold + code removal are inseparable — the compiler will not build with fields removed from types but still referenced). Draft → local verification (§6) → adversarial review → Ready.
