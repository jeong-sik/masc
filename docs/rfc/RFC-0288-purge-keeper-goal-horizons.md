# RFC-0288: Purge keeper goal-horizon fields (short_goal / mid_goal / long_goal)

- Status: Draft
- Author: vincent (+ Claude Opus 4.8)
- Created: 2026-06-23
- Supersedes scope: reverses the "kept" disposition recorded in RFC-0282 §3 ("Goal horizons … a separate live concern, kept")
- Related: RFC-0282 (de-structure keeper self_model), RFC-0067/0109/0111/0267/0284 (the *separate* Goal_store / goal-tree subsystem — untouched)
- Implementation PRs: (this RFC's PR)

## 1. Summary

Remove the three structured per-keeper meta string fields `short_goal` / `mid_goal` / `long_goal` (the "goal horizon" triple) and all of their plumbing. The single `goal` field stays. The horizon text is **not** dropped: for every keeper whose horizons differ from `goal`, the verbatim text is folded into the keeper's `instructions` prose (as a labeled "목표 계층" block) before the fields are deleted. No keeper loses authored intent; the model conditions on the same text, now as ordinary instruction prose rather than as a labeled `Short/Mid/Long-term goal` state block.

This is the direct sequel to RFC-0282. RFC-0282 removed the `will`/`needs`/`desires` self-model triple and explicitly left the goal horizons in place as "a separate live concern." A subsequent adversarial audit (2026-06-23) found the horizon triple has the same defect RFC-0282 cured: it is a **labeled structure with no mechanism consuming the structure**.

## 2. Motivation

### 2.1 The horizon *split* is consumed by nothing — there is no scheduler

The short/mid/long-term vocabulary implies a temporal planning system (短=now, 中=weeks, 長=ongoing). No such system exists. The audit traced every reference of `short_goal`/`mid_goal`/`long_goal` in `lib/`:

- **Turn initiation is channel-driven, not goal-driven.** Keeper turns start via board signals, task events, heartbeat, chat, and polling. `rg 'short_goal|mid_goal|long_goal'` over the turn/scheduler paths returns **0** — the horizon is not an input to any scheduling, decay, deadline, priority, or task-selection decision.
- **The two non-display consumers flatten the split away.** `keeper_world_observation_board_signal.ml` `stigmergy_match` builds `[goal; short_goal; mid_goal; long_goal]` and `sort_uniq`s it into one keyword bag (horizon identity erased). `keeper_memory_recall.ml` `goal_horizon_candidates` likewise folds `[short; mid; long; goal]` into one deduped list with a max-Jaccard fold. Neither weights or distinguishes a horizon.
- **The "goal-loop" OODA surface is observability, not control.** `Dashboard_goal_loop.status_json` is a 5 s-TTL read model over `<masc_dir>/goal-loop/status.json` exposed at `GET /api/v1/dashboard/goal-loop/status`; RFC-0284 §1 calls it "the most live-feeling dashboard surface." It does not pick keeper actions.

So the horizon split's *only* genuine effect is that its text reaches the LLM prompt (§2.2). Everything else flattens or displays it.

### 2.2 Honest accounting: the *text* is load-bearing, hence content-preserving (not blind deletion)

The horizon text is injected into the keeper LLM system prompt:

- `keeper_unified_prompt.ml:687-694` (`build_prompt`, the live per-turn `system_prompt` at `keeper_unified_turn.ml:254-261`) renders `line_block "Short-term goal" / "Mid-term goal" / "Long-term goal"` **guarded by `meta.X_goal <> "" && meta.X_goal <> meta.goal`**. The guard fires for the keepers that author distinct horizons.
- `keeper_prompt.ml:293-304` (`build_keeper_system_prompt`) emits `"- Short-term: "/"- Mid-term: "/"- Long-term: "` **unconditionally**, but its output is `base_system_prompt`, which the live turn discards (`keeper_unified_turn.ml` `build_turn_prompt` ignores it; `keeper_agent_run.ml:492` runs `~system_prompt:turn_system_prompt`). Its only live consumer is the dashboard `effective_system_prompt` preview (`dashboard_http_keeper_snapshot.ml:102-112`) — a preview/reality drift (the preview shows three goal-duplicate lines for collapsed keepers while the model sees one).

Because the text reaches the model, this is a **behavior change**, and its magnitude is **unmeasured** (no eval asserts on horizon outcomes; the 9 tests covering these fields assert on parse/overlay/drift/schema-key-presence, none on the short-vs-mid-vs-long distinction — they would pass if all three collapsed to `goal`). Mitigation: content preservation (§5) — the authored text is folded into `instructions`, so the prompt still carries it, de-labeled and de-structured.

### 2.3 Default collapse-to-goal confirms the structure is hollow

`resolve_goal_horizons` (`keeper_config_text.ml:233-251`) does `Option.value ~default:goal X_goal_opt` for each unset horizon. Empirically (2026-06-23), of the goal-bearing keeper configs, ~8 set no horizons (they collapse entirely to `goal`); the rest author distinct text. The field is therefore either a duplicate of `goal` or free-form aspiration prose — in neither case does the *structure* (three typed fields + ~20 files of plumbing) earn its keep over the existing `instructions` channel.

### 2.4 If horizon-aware planning is ever wanted, Goal_store is the substrate — not these strings

`Goal_store` already carries a `Short | Mid | Long` horizon variant **plus** convergence, task↔goal binding, and the goal-loop OODA. A real horizon planner (decay/escalation/time-windowed task selection) would be built there, not on dumb per-keeper meta strings. Removing these strings does not foreclose that feature; it removes a structure that falsely advertises it.

## 3. Non-goals (explicitly preserved)

- **`Goal_store` and its `Short | Mid | Long` horizon** (`lib/goal/*`, `active_goal_ids`, `<available_goals>` prompt block, convergence, task↔goal) — a different subsystem; kept untouched.
- **Memory horizons** (`short_term_horizon` / `mid_term_horizon` / `long_term_horizon` in `lib/keeper/keeper_memory_*`) — unrelated; kept.
- **`goal`** — the single keeper goal field; kept (and the prompt still renders `Goal: <goal>`).
- **`persona_name` / `role` / `trait` / `instructions`** — kept; `instructions` is the fold target.
- **The goal-loop OODA dashboard surface (RFC-0284)** — kept.

## 4. Surface inventory

| path | role | disposition |
|---|---|---|
| `config/personas/*/profile.json` (19) | `keeper.short_goal`/`mid_goal`/`long_goal` | fold → `keeper.instructions`, delete keys |
| `config/keepers/masc-improver.toml` | horizon lines | fold → `instructions`, delete keys |
| `<masc_dir>/config/keepers/*.toml` (6, runtime) | horizon lines | runtime migration (out-of-PR data; same fold) |
| `lib/keeper/keeper_meta_contract.ml/.mli` | `keeper_meta.{short_goal,mid_goal,long_goal}`, `apply_profile_default` | delete fields |
| `lib/keeper/keeper_config_text.ml` | `resolve_goal_horizons`, `normalize_goal_horizon_opt`, `parse_goal_horizon_opt` | delete (dead) — **KEEP `normalize_goal_horizon_text` / `default_goal_horizon_max_chars` / `MASC_KEEPER_GOAL_HORIZON_MAX_CHARS`: they normalize the surviving `goal` field, see §9** |
| `lib/keeper/keeper_meta_json_parse.ml` | `pk_short/mid/long_goal` | delete |
| `lib/keeper/keeper_types_profile{,_defaults,_persona_defaults,_toml_parser,_toml_normalizers}.ml` | profile-default option fields + TOML parse/overlay + canonical key names | delete |
| `lib/keeper/keeper_turn_up_create.ml` | horizon resolution + JSON emit (keep `active_goals`) | delete horizon parts |
| `lib/keeper/keeper_prompt.ml/.mli` | `~short_goal ~mid_goal ~long_goal` params + `<identity>` horizon lines | delete (keep `Goal:` line + `<available_goals>`) |
| `lib/keeper/keeper_unified_prompt.ml` | guarded `Short/Mid/Long-term goal` line_blocks | delete |
| `lib/keeper/keeper_run_context.ml`, `keeper_context_runtime.mli`, `keeper_execution.mli` | pass-through args | delete |
| `lib/keeper/keeper_world_observation_board_signal.ml` | `[goal;short;mid;long]` keyword bag | collapse to `[goal]` |
| `lib/keeper/keeper_memory_recall.ml` | `goal_horizon_candidates` | collapse to `[goal]` |
| `lib/keeper/keeper_runtime.ml` | horizon `drift_if` entries | delete |
| `lib/operator/operator_control_snapshot{,_trust,_persistent_agents}.ml` | serialized fields (RFC-gated subsystem) | delete |
| `lib/dashboard/dashboard_http_keeper{,_snapshot}.ml`, `keeper_status_detail.ml`, `keeper_status.ml`, `dashboard_execution_{builders,fixture}.ml`, `dashboard_briefing_assembly.ml`, `server_dashboard_http_namespace_truth_support.ml` | emit / focus / current_work / keeper_has_goal | delete emits; repoint focus/current_work/keeper_has_goal → `goal` |
| `lib/tui_decode.ml/.mli`, `bin/masc_tui_render.ml` | `k_short_goal` decode + render | delete |
| `dashboard/src/**` (TS: types/core.ts, api/dashboard.ts, keeper-goal-horizons-panel.ts, keeper-detail-body.ts, keeper-cognition-inspector.ts, keeper-config-panel.ts, keeper-runtime-display.ts, fleet-telemetry-utils.ts, agent-roster.ts, + tests) | types/render/edit/fallbacks | delete; collapse fallbacks → `goal`; delete goal-horizons panel |
| `test/test_keeper_{toml,prompt_external,prompt_metrics,status_bridge,effective_meta_overlay}.ml`, `test_personality_diff_summary_10269.ml`, `test_tools_coverage.ml`, `test_tui_decode.ml`, `test_operator_control_snapshot.ml` | field assertions | remove/update |

## 5. Migration design

1. **Config (content-preserving first, deterministic).** A mechanical script folds each keeper's non-empty horizon text verbatim into its `instructions` as a labeled "목표 계층" block, then deletes the three keys — from both `config/personas/*/profile.json` and `config/keepers/*.toml`. No judgment, no data loss. Runtime configs (`<masc_dir>/config/keepers/*.toml`) are migrated by the same script as an out-of-PR data step; un-migrated runtime configs degrade gracefully (unknown TOML keys are WARN-and-ignore, not fail-loud — `keeper_types_profile_toml_parser.ml` `warn_unknown_keeper_toml_keys`).
2. **Types + parsers (compiler-driven).** Remove the fields from `keeper_meta`, `keeper_profile_defaults`, both parsers, and `canonical_keeper_toml_key_names`. The OCaml compiler enumerates every consumer; each error site is resolved explicitly (no `_` catch-all added).
3. **Prompt assembly.** Remove the `Short/Mid/Long-term goal` render blocks and the `~short_goal ~mid_goal ~long_goal` parameters. `<identity>` keeps `Goal: <goal>` and the separate `<available_goals>` Goal_store block.
4. **Non-display consumers.** Collapse the stigmergy and memory-recall keyword sources to `[goal]` (no behavior change — already flattened).
5. **Dashboard + operator + TUI.** Remove emits; repoint `focus`/`current_work`/`keeper_has_goal` to read `goal`; the TS compiler drives the frontend type/component removal; delete the goal-horizons panel.
6. **Tests.** Remove horizon args/assertions; none assert on the distinction, so changes are mechanical.

## 6. Acceptance criteria

- No `keeper_meta` / `keeper_profile_defaults` **field** references remain: `rg '\.short_goal|\.mid_goal|\.long_goal|~short_goal|~mid_goal|~long_goal|pk_short_goal|short_goal_opt' lib/ test/ bin/` → 0 (excluding the §9 intentional survivors).
- `config/personas/*/profile.json` and `config/keepers/*.toml` carry no `short_goal`/`mid_goal`/`long_goal` keys (the text is folded into `instructions`).
- `dune build` green; affected OCaml tests pass; `ocamlformat --check` clean.
- `tsc --noEmit` 0; `vitest run` pass; `eslint` 0.
- Each migrated keeper's effective `instructions` retains its prior horizon text (diff recorded in PR).

## 7. Risks

- **Behavior change (acknowledged, §2.2):** the prompt loses the labeled horizon blocks; the text moves into `instructions`. Magnitude unmeasured. Mitigation: verbatim content preservation; reversible via git.
- **Reverses RFC-0282's "kept" disposition:** RFC-0282 §3 listed horizons as kept. This RFC supersedes that one line with the §2 audit evidence (no mechanism consumes the structure). The rest of RFC-0282 is unaffected.
- **RFC-gated operator surface:** `lib/operator/operator_control_snapshot*` is in the CLAUDE.md agent_delegation RFC-gate list; this RFC is the gate.
- **Persisted meta JSON / runtime configs:** older snapshots and un-migrated runtime TOMLs may still carry the keys; readers ignore unknown keys (named-field reads; WARN-and-ignore on TOML), so absence is safe and presence is harmless.
- **Preview/reality drift removed as a side effect:** deleting `keeper_prompt.ml`'s unconditional horizon emit also fixes the dashboard `effective_system_prompt` preview showing triplicated goal lines.

## 8. Rollout

Single PR (the config fold + code removal are inseparable — the compiler will not build with fields removed from types but still referenced). Draft → local verification (§6) → adversarial review → Ready. Runtime config migration applied to `<masc_dir>` as an out-of-band data step alongside merge.

## 9. Intentional survivors (not vestigial — documented to avoid mistaken "incomplete purge" reads)

Three identifiers keep the word "goal_horizon" or the horizon key names after the purge. They are kept on purpose because they serve the surviving `goal` field or the migration boundary — not the removed horizon structure:

1. **`normalize_goal_horizon_text` / `default_goal_horizon_max_chars` / `MASC_KEEPER_GOAL_HORIZON_MAX_CHARS`** (`keeper_config_text.ml`, re-exported via `keeper_config.mli` / `keeper_types_profile_toml_*.mli`). This is the trim + UTF-8 byte-cap normalizer applied to the surviving `goal` field at ~10 sites (`keeper_meta_json_parse.ml:71`, `keeper_prompt.ml:182`, `keeper_turn_up_create.ml`, `keeper_runtime.ml` drift, …). Removing it would orphan `goal`'s normalization. The `_horizon_` in the name is now historical; a rename to `normalize_goal_text` / `MASC_KEEPER_GOAL_MAX_CHARS` is a clean follow-up (the env-var rename is a minor operator-compat note), deliberately deferred to keep this PR a pure field purge.
2. **`removed_keeper_msg_input_key_names`** (`keeper_config_text.ml`) keeps `short_goal`/`mid_goal`/`long_goal`/`new_short_goal`/… alongside `goal`/`instructions`. This is the keeper-MSG-tool reject list: identity/config keys passed to the wrong tool are rejected with "Use masc_keeper_up …". Keeping the removed key names yields a helpful migration error for stale callers rather than a silent ignore — same treatment as `goal`/`instructions` (which are also live and listed here).
3. **`test_personality_diff_summary_10269.ml`** used `"short_goal"`/`"mid_goal"` as **opaque string labels** fed to a generic per-field diff function (test data, not `keeper_meta` field references). To avoid leaving the removed names anywhere, the labels were renamed to surviving fields (`"persona"`/`"trait"`), preserving the exact diff arithmetic; the test passes (8). No survivor here — listed for completeness.
