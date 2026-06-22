# RFC-0275: Excise the BDI triple (belief/desire/intention) from the keeper social model

- Status: Draft
- Author: jeong-sik (with adversarial agent audit, 2026-06-21)
- Supersedes/Touches: social model introduced via `keeper-social-model-*` design docs; retires `magentic_ledger_v1`
- Related: RFC-0239 (no-progress loop detector moved control flow onto `delivery_surface` + tool evidence), RFC-0232, #5573 (declare-via-headers 0-tool-call failure)

## 1. Summary

Remove the three "BDI" narrative fields — `belief_summary`, `active_desire`,
`current_intention` — from the keeper social model end to end (prompt protocol,
`social_state` record, parse, carry, persistence, metrics, dashboard). Keep the
fields that gate real control flow: `speech_act`, `delivery_surface`, `blocker`.
Retire the never-assigned `magentic_ledger_v1` model, whose phase serializer
is the BDI triple itself.

This is a structural change: it alters a product type (`social_state`), the
`keeper_meta` runtime contract, and two persisted JSON formats (checkpoint,
decision JSONL), spanning ~17 modules. Hence an RFC rather than a direct PR.

## 2. Motivation (evidence, not theory)

The BDI triple is **not load-bearing in shipped behavior** — it is
parse/cap/persist/render only:

1. Negative evidence: `rg` of `.belief_summary` / `.active_desire` /
   `.current_intention` over `lib/ bin/` excluding the owning libs returns 7
   hits, all `Option.value ~default` / string copies into metrics — zero
   `if`/`match` branches (`keeper_unified_metrics_result.ml:236,238`,
   `keeper_unified_metrics_failure.ml:165,170`,
   `keeper_unified_metrics_decision.ml:96-98`).
2. The only function that branches on triple *content* is the magentic FSM
   phase recovery (`keeper_social_model_magentic_ledger_fsm.ml:145-159`), and it
   is gated `if not (normalize_social_model state.social_model = model_name) then
   None` (`:161-163`) — unreachable for the default `bdi_speech_v1`.
3. `magentic_ledger_v1` is assigned to **no keeper** (empty `config/` + `.masc/`
   grep); default model is `bdi_speech_v1` (`lib/config/env_config_core.ml:525-527`).
4. On carry, `belief_summary` is overwritten to the literal `"runtime_carry"`
   (`keeper_social_model.ml:131`), so even the magentic belief-phase path is
   structurally dead.
5. The genuine production decision — the no-progress loop detector — branches on
   `delivery_surface`, **not** the triple, by deliberate RFC-0239 design
   (`keeper_unified_turn_success.ml:88-92`).

It is **redundant**: the `[STATE]` block (DONE/NEXT/Goal/Decisions/...) and the
injected `goal_lines` already carry the same narrative each turn. Only
`[STATE].Goal` is validated against `active_goal_ids`
(`keeper_state_block_prompt.ml:9-12`); the triple carries no such dependency.

It has **negative precedent**: the declare-intent-via-headers design caused
0-tool-call proactive turns (#5573). No eval/benchmark ever validated BDI
(`docs/design/keeper-social-model-inventory.md:75-76`).

It has a **recurring cost**: the static instruction (~160 tokens) is
prefix-cacheable, but the keeper emits three triple header lines as
**non-cacheable output tokens every turn**, fleet-wide, feeding only
parse/cap/persist/render.

## 3. Non-goals (what stays)

- `speech_act` — gates request-help routing + reply suppression
  (`keeper_social_model_bdi_speech_v1.ml:378-398`) and is a protocol-violation
  gate key. **Keep.**
- `delivery_surface` — load-bearing for the no-progress loop detector
  (`keeper_unified_turn_success.ml:88-92`) and accountability surface label.
  **Keep.**
- `blocker` — load-bearing for request_help dedup/routing
  (`bdi_speech_v1.ml:259-298`) and carries structured `[masc_oas_error]`
  payloads (#9933 `cap_blocker`). **Keep.**
- `need` — decorative (render/metrics only). **May** be removed in the same PR
  if the compiler stays green; not required. Default: keep this round to bound
  blast radius.
- Replacing the SPEECH_ACT/DELIVERY_SURFACE *self-declared header protocol* with
  tool-call inference is a separate proposal (Phase 2) because it touches the
  no-progress safety net and needs behavioral testing. **Out of scope here.**

## 4. Decision: retire magentic_ledger_v1

`magentic_ledger_v1` has no separate phase field — the BDI triple *is* its wire
format (`magentic_ledger_v1.ml:115,212` round-trip). It is assigned to no
keeper and exists "to validate the abstraction"
(`docs/design/keeper-social-model-fsm.md:26`). Stripping the triple while leaving
magentic compilable-but-broken is forbidden (silent breakage). We **retire** it:
delete `keeper_social_model_magentic_ledger_v1.ml`,
`keeper_social_model_magentic_ledger_fsm.ml`, and the registry target. The
alternative (re-ground magentic on a typed `runtime.last_phase`) is recorded but
rejected as unjustified work for an unused model.

## 5. Removal plan (compiler-driven; delete fields, fix every error)

1. `config/prompts/keeper.unified.system.md`: drop `BELIEF_SUMMARY` /
   `ACTIVE_DESIRE` / `CURRENT_INTENTION` emit lines (keep SOCIAL_MODEL, BLOCKER,
   NEED, SPEECH_ACT, DELIVERY_SURFACE).
2. `lib/keeper_social/keeper_social_model_types.ml(.mli)`: remove the three
   fields from `social_state`; remove `default_belief_summary_max_chars` and the
   triple slice of `cap_social_state`.
3. `lib/keeper/social_model/keeper_social_model_bdi_speech_v1.ml(.mli)`: remove
   `belief_summary_of_observation`, the triple reads in `social_state_of_headers`,
   and triple carry in `make_state`. Leave the SPEECH_ACT+DELIVERY_SURFACE gate
   intact.
4. `lib/keeper/keeper_social_model.ml`: in `previous_state_of_meta`, drop the
   `belief_summary="runtime_carry"` literal and the `last_active_desire` /
   `last_current_intention` reconstruction; keep `speech_act`/`blocker`/`need`.
5. `lib/keeper/keeper_meta_contract.ml(.mli)`: remove
   `runtime.last_active_desire` / `last_current_intention` (and
   `last_belief_summary` if present).
6. `lib/keeper/keeper_meta_json.ml` + `keeper_meta_json_parse.ml`: remove
   serialize/parse of the triple `last_*` fields. **Tolerate-and-drop unknown
   keys on read** so existing checkpoints resume.
7. `lib/keeper/keeper_unified_metrics_result.ml` / `_failure.ml` /
   `_decision.ml`: remove triple copies into metrics/decision JSONL.
8. `lib/dashboard/dashboard_http_keeper_snapshot.ml` /
   `dashboard_http_keeper_feeds.ml`: remove triple from the read-only
   bdi-snapshot JSON projection.
9. `dashboard/src`: update `inspector-keeper-bdi.ts`,
   `bdi-snapshot-trace-bridge.ts`, `keeper-bdi-panel.ts` and their tests
   (render-only; degrade to `-`).
10. Retire magentic per §4.
11. `lib/meta_cognition*` if it carries triple fields (compiler will flag).

Verification: `dune build --root .` in the worktree (NOT root — nested-worktree
dune trap), then `dune runtest --root .` for the affected test stanzas.

## 6. Persistence migration & rollback

- Checkpoint (`keeper_meta` runtime) and decision JSONL drop the triple `last_*`
  keys. Readers must already tolerate unknown keys; confirm and add a test if
  not. No data backfill needed — fields are advisory.
- Rollback: revert the PR. Old checkpoints written without the keys load fine
  (fields were optional/defaulted). New checkpoints lack the keys; a revert
  re-introduces defaulted empties — no corruption.

## 7. Risks

1. magentic silent breakage if triple stripped without retiring it (§4 mitigates).
2. Checkpoint/decision JSON format change — needs tolerate-and-drop on read.
3. Forensic-narrative loss: decision JSONL + bdi-snapshot endpoint are the
   operator "why did the keeper act" record. Real (non-control-flow)
   observability regression; `[STATE]` block + tool-call log partially cover it.
4. No eval either direction — removal is unmeasured. Mitigation: brief
   before/after keeper sanity check (tool-call rate, loop-detect rate), given
   #5573.
5. Touches an abstraction boundary framed as intentional — owner sign-off.

## 8. Verification / acceptance

- `dune build @check --root .` green (whole-tree typecheck; the closed-sum
  deletions make the compiler enumerate every consumer).
- `dune runtest` green for the cap/social stanzas that run standalone:
  `test_social_state_cap` (5/5), `test_cap_blocker_structured_error` (8/8),
  `test_social_state_cap_on_load` (5/5). `test_dashboard_k2_feeds` cannot run
  standalone (pre-existing — see §9.8); its BDI-relevant case
  (`json shape matches spec`) was verified green under a temporary local
  runtime-init.
- `rg 'belief_summary|active_desire|current_intention|BELIEF_SUMMARY|ACTIVE_DESIRE|CURRENT_INTENTION'`
  over `lib/ bin/ config/prompts dashboard/src` returns only intentional residue
  (e.g. back-compat tolerate-and-drop comments).
- A resumed keeper loads a pre-change checkpoint without parse error (test).
- TLA+ gates green after the magentic spec retirement (see §9.9):
  `scripts/check-spec-truth.sh` → 0 orphans, `scripts/ci/check-tla-harness-coverage.sh`
  → PASS, `specs/INDEX.md` regenerated to match `scripts/gen-tla-index.sh` output.

## 9. Implementation notes (as-built)

Deviations from the §5 plan discovered during implementation:

1. **§5 item 11 (`lib/meta_cognition*`) was a false positive — NOT touched.**
   `meta_cognition_types.ml` has its own `belief_summary` record
   (`dominant_belief` etc.) unrelated to `social_state`. `rg` of
   `social_state|Keeper_social_model|last_active_desire|last_current_intention`
   over `lib/meta_cognition*` returns zero hits.
2. **`last_belief_summary` does not exist** in the runtime contract — only
   `last_active_desire` and `last_current_intention` were persisted
   (`keeper_meta_contract` runtime). Both removed.
3. **`need` was KEPT** (decorative but cheap; bounds blast radius). `blocker`,
   `speech_act`, `delivery_surface` kept (load-bearing, per §3).
4. **`apply_to_result` lost its `~observation` parameter.** The triple's only use
   of the world observation was belief synthesis
   (`belief_summary_of_observation`); with that gone, `bdi_speech_v1.apply_to_result`
   no longer branches on observation, so `~observation` was removed from
   `bdi_speech_v1` / `keeper_social_model_registry` / the `Keeper_social_model`
   facade / the call site in `keeper_unified_turn_success.ml`. `derive_failure_state`
   keeps `~observation` (it branches on `claimable_task_count`).
5. **magentic fully retired:** deleted `keeper_social_model_magentic_ledger_v1.ml(.mli)`,
   `keeper_social_model_magentic_ledger_fsm.ml(.mli)`, the `Magentic_ledger_v1`
   `model_id` variant, the now-orphaned `Tool_only_progress_ledger`
   `transition_reason` variant, and the `test_magentic_ledger_cap` /
   `test_keeper_social_model_magentic_ledger_fsm` tests (+ `test/dune` refs).
6. **Dashboard FRONTEND (TS) deferred to a follow-up.** This PR changes only the
   OCaml `bdi-snapshot` endpoint (`belief`/`desire`/`intention` →
   `blocker`/`need`). The Preact BDI inspector + RFC-0028 trace-replay
   (`inspector-keeper-bdi.ts`, `bdi-snapshot-trace-bridge.ts`,
   `overlay-keeper-trace.ts`, `keeper-trace-store.ts`) are a self-contained,
   vitest-only subsystem; reworking them here would be unverifiable in the
   worktree (no `node_modules`) and un-reviewable bundled with a 17-module backend
   change. They degrade gracefully (empty belief/desire/intention rows; `need`
   still shows) until the follow-up.
7. **Checkpoint back-compat is automatic.** Removing the parse reads in
   `keeper_meta_json_parse.ml` means old `last_active_desire`/`last_current_intention`
   keys are simply not consumed (dropped). `warn_unknown_keeper_meta_keys` logs a
   one-time benign warning on first resume; the keeper self-heals on its next
   checkpoint write. No parse failure, no backfill.
8. **`test_dashboard_k2_feeds` is a pre-existing dead test — out of scope.**
   Its `keeper_meta` helper calls `Keeper_config.default_runtime_id ()` →
   `Runtime.get_default_runtime_id ()`, which raises when the runtime is not
   initialized (RFC-0206 §2.1). The harness never calls `Runtime.init_default`,
   so all 7 cases crash before any assertion — on `origin/main` too (the helper
   is byte-identical). My change to this file is only the removal of a now-stale
   `current_intention`/"deploy" assertion (the field is gone). I verified the
   change by temporarily adding the sibling `Runtime.init_default` idiom: the
   BDI-relevant case passed, but doing so surfaced **three pre-existing,
   BDI-unrelated failures** (evidence-ref whitespace not trimmed in
   `keeper_decisions_log_json`; memory-log same-timestamp id collision;
   memory-log kind mapping). Enabling the test here would couple this PR to
   those unrelated bugs, so the runtime-init enabler was reverted. The
   runtime-init gap + the three surfaced bugs are recorded separately (Issue
   Discovery Protocol) for a focused follow-up.
9. **magentic TLA+ spec deleted in-PR; `SocialStateCap.tla` semantic edit deferred.**
   Initial scoping deferred both specs citing TLC (Java), which this worktree
   cannot run. **That was wrong for the magentic spec.** The **Meta Guards**
   bug-class gate `scripts/check-spec-truth.sh` scans `Mirrors:` annotations and
   flagged `KeeperSocialModelMagenticLedger.tla` as an orphan reference to the
   deleted `keeper_social_model_magentic_ledger_fsm.ml` (CI red on the first
   push). Deletion — not TLC — is the correct repair (the gate's own message:
   "remove the annotation if the mechanism was intentionally deleted"). So this
   PR retires the spec atomically with the FSM:
   - deleted `KeeperSocialModelMagenticLedger.{tla,cfg,-buggy.cfg}`
   - removed the two `run_tlc`/`run_tlc_buggy` lines from `scripts/tla-check.sh`
     (the harness-coverage gate `scripts/ci/check-tla-harness-coverage.sh` then
     passes because the spec is no longer cfg-backed)
   - regenerated `specs/INDEX.md` via `scripts/gen-tla-index.sh` (pure bash, no
     TLC; the row drops, counts adjust 93→92 `.tla` / 192→190 `.cfg`). The
     `tla-index.yml` comparator ignores the `Generated:` header line.
   - removed the now-orphaned magentic mirror section from
     `test/test_clean_only_bug_mirrors.ml` (the OCaml analogue of the deleted
     spec's `StalledNeedsGoalOrFailure` invariant)
   Verified locally without TLC: `check-spec-truth.sh` → 0 orphans / PASS;
   `check-tla-harness-coverage.sh` → PASS; `make -C specs` discovers cfgs via
   `find` so the deletion drops cleanly from the matrix; no other `.tla`
   `EXTENDS`/`INSTANCE`s the module.
   - **Still deferred (genuinely CI-safe):** `specs/social-state-cap/SocialStateCap.tla`.
     Its `EmitClean` caps `belief`/`desire`/`intention`, which `cap_social_state`
     no longer touches (blocker+need only). It has **no** `Mirrors:` annotation
     to a deleted file, so `check-spec-truth.sh` does not flag it; it is
     self-consistent abstract TLA+ that still model-checks green. The semantic
     edit (rewrite `EmitClean`/invariants on blocker+need) needs TLC
     verification, so it stays a follow-up (#22024), along with its `:58`
     comment that references the deleted `keeper_social_model_magentic_ledger_v1.ml`.
