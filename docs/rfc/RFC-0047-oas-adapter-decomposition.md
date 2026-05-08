# RFC-0047 — `oas_*` adapter family decomposition (consumer-only OAS boundary)

Status: Draft
Author: jeong-sik
Date: 2026-05-08
Supersedes: —
Related: RFC-0045 (SDK turn boundary alignment), RFC-0046 (FsmHub SSOT),
keeper sub-library extraction analysis (memory
`project_keeper_sublib_extraction_analysis.md`)

## 1. Problem

`masc-mcp/lib/` carries an `oas_*` prefix family of 16 source files
(11,249 LOC across `.ml` + `.mli`) that *aspirationally* names them as
"the OAS layer", but in fact:

- The **real OAS** is a separate repository at
  `~/me/workspace/yousleepwhen/oas`, exposed as the `agent_sdk` opam
  library (310 source files, library name `agent_sdk`). It has zero
  references to `Keeper_*`, `Cascade_*`, `Masc_*`, `Dashboard_*`,
  `Briefing_*`, `Board_*`. The repo boundary already enforces "OAS knows
  nothing about MASC".

- `masc-mcp/lib/oas_*.ml` is **not** OAS. It is MASC's consumer/adapter
  layer for OAS. masc-mcp is a *consumer* of `agent_sdk`, nothing more.

- The 16 files mix three concerns into a single dumping ground:

  | Concern | Belongs in |
  |---|---|
  | A. Pure `agent_sdk` invocation (build prompt, run loop, parse response) | `agent_sdk` library or thin wrapper in masc-mcp |
  | B. Cascade strategy (provider rotation, retry decision, exhaustion classification) | `lib/cascade/` |
  | C. Keeper bookkeeping (status updates, observation lifecycle, FSM transitions) | `lib/keeper/` |

- Concrete cross-domain reference count (rg measured 2026-05-08):

  | File | Cross-domain refs | LOC |
  |---|---|---|
  | `oas_worker_named.ml` | 103 | 1459 |
  | `oas_worker_named_cascade.ml` | 25 | (in 153 mli + ml) |
  | `oas_worker_named_fsm.ml` | 19 | 653 |
  | `oas_worker_exec.ml` | 16 | (300 mli) |
  | `oas_worker_exec_transport.ml` | 16 | (318 mli) |
  | `oas_events.ml` | 15 | (198 mli) |
  | `oas_worker_named_error.ml` | 13 | (163 mli) |
  | `oas_worker_cascade.ml` | 6 | (238 mli) |
  | `oas_worker_exec_agent.ml` | 4 | (133 mli) |
  | `oas_event_bridge.ml` | 4 | (63 mli) |
  | `oas_model_resolve.ml` | 3 | (18 mli) |
  | `oas_worker_exec_checkpoint.ml` | 1 | (90 mli) |
  | `oas_worker.ml` | 0 | 16 |
  | `oas_response.ml` | 0 | (16 mli) |
  | `oas_log_bridge.ml` | 0 | (28 mli) |
  | `oas_bus_instrument.ml` | 0 | (82 mli) |
  | **Total** | **234** | **~11,249** |

  Top three modules referenced from `oas_worker_named.ml`:
  `Cascade_fsm` (26), `Keeper_types` (17), `Cascade_health_tracker` (11).
  These are **strategy and bookkeeping**, not Agent SDK calls.

- Caller surface: `rg -l 'Oas_worker_named\.|Cascade_runner\.|Oas_worker\.'` reports
  **49 files in `lib/`** (20 keeper-side, 2 cascade-side, 27 elsewhere) plus
  test/bin = **504 total references**. Any rename or extraction must
  preserve these call sites or migrate them in lockstep.

## 2. Why this matters (failure modes already observed)

1. **Production assert fan-out crosses three layers.** RFC-0045 root cause
   was a `Turn_finalizing → Turn_prompting` validator failure inside a
   hook closure executed by `Agent_sdk__Agent.run_loop.(fun).loop`. The
   stack trace traversed `Cascade_runner.run` → `Memory_hooks` → keeper
   `update_current_turn`. A 4-layer interleave (SDK loop ↔ adapter ↔
   hooks ↔ keeper bookkeeping) made root-causing slow because the layer
   responsible for the bookkeeping invariant was hidden inside an
   `Oas_*`-named file.

2. **Cascade RFCs are forced to edit `oas_*` files.** RFC-0041 (cascade
   routing group hierarchy) modified `oas_worker_named_cascade.ml` even
   though the change was purely cascade strategy. Cascade authors must
   either learn the OAS-named adapter idiom or risk wrong-layer change.

3. **Aspirational naming creates anti-learning.** AI agents (Claude /
   Codex / Gemini) trained on this codebase will infer that "OAS knows
   about Cascade" is an accepted pattern, since 26+ Cascade refs live in
   an `oas_*`-named file. Future code generation reproduces the pattern.
   This is exactly the workaround-as-precedent mechanism documented in
   `instructions/software-development.md` §"워크어라운드 거부 기준".

4. **Sub-library extraction (keeper) blocked by undefined cascade
   boundary.** The keeper sub-lib extraction analysis (memory
   `project_keeper_sublib_extraction_analysis.md`) found 189 keeper ↔ 118
   external refs and concluded "shared types library + dependency
   inversion" is needed first. The cascade boundary is a prerequisite for
   that inversion — but cascade is currently entangled with `oas_*`.

## 3. Constraints

- **No behavior change.** This RFC is a structural refactor. Public
  agent-facing behavior (provider selection, retry, response shape) MUST
  be byte-identical at the keeper-driver call site.
- **Build green at every PR.** Each phase's PR must compile, pass
  existing tests, and not introduce new warnings (especially partial
  match warnings that the issue #14195 sweep just closed).
- **Single direction dependency.** No new file may add a reverse edge
  (lower layer importing upper layer). Verified per phase via dune build
  graph.
- **Concurrent activity.** Keeper sub-library extraction work (memory
  `project_keeper_sublib_extraction_analysis.md`) and FsmHub SSOT
  (RFC-0046, in flight) MUST be coordinated. Cascade extraction (this
  RFC's phase 3) and keeper extraction touch overlapping files.
  Recommendation: serialize. This RFC lands first.
- **`include_subdirs unqualified` retained.** The single-library flat
  layout is keeping the build graph simple. We do NOT introduce dune
  sub-libraries in this RFC; the boundary becomes structural via
  directory placement and `.mli` discipline, not link-level enforcement.
  A follow-up RFC may convert to dune sub-libraries once cycles are
  resolved.

## 4. Target architecture

```
agent_sdk            (~/me/workspace/yousleepwhen/oas, separate repo)
   ↑ direct call only
lib/agent_sdk_call/  (thin invocation wrapper, no domain logic)
   ↑
lib/cascade/         (provider rotation, retry, exhaustion)
   ↑
lib/keeper/          (lifecycle, state, observation, status)
   ↑
server, dashboard, ag_ui, briefing
```

Single direction. Cascade does not know keeper. agent_sdk_call does not
know cascade. agent_sdk (external repo) knows none of it (already true).

### 4.1 The `oas_*` prefix is retired

After full migration, `lib/oas_*.ml` does not exist. The prefix is
banned. New code referring to "OAS" outside the external repo is a
review block.

Reason: the prefix attracts dumping. Every refactor that needed "a place
to put the SDK call" landed in `oas_worker_named.ml`. Removing the
prefix removes the gravity well.

### 4.2 What replaces it

- **`lib/agent_sdk_call/`** — 4 clean files (`oas_worker.ml`,
  `oas_response.ml`, `oas_log_bridge.ml`, `oas_bus_instrument.ml`),
  renamed to `agent_sdk_call.ml`, `agent_sdk_response.ml`,
  `agent_sdk_log_bridge.ml`, `agent_sdk_metrics_bridge.ml`. Pure
  agent_sdk wrapping. Zero MASC domain refs (already the case today).

- **`lib/cascade/`** — receives the cascade-execution files: rotation,
  retry FSM, exhaustion classifier, model resolve, transport
  construction, cascade events.

- **`lib/keeper/`** — receives the keeper-bookkeeping files: turn driver
  (the keeper-facing entry point that owns observation updates),
  checkpoint, agent context build.

## 5. File-by-file plan

| Current path | Action | Destination | Phase |
|---|---|---|---|
| `oas_worker.ml` (16 LOC) | rename | `lib/agent_sdk_call.ml` | 2 |
| `oas_response.ml` | rename | `lib/agent_sdk_response.ml` | 2 |
| `oas_log_bridge.ml` | rename | `lib/agent_sdk_log_bridge.ml` | 2 |
| `oas_bus_instrument.ml` | rename | `lib/agent_sdk_metrics_bridge.ml` | 2 |
| `oas_event_bridge.ml` | move (already bridge-shaped) | `lib/cascade/cascade_event_bridge.ml` | 5 |
| `oas_events.ml` | move + invert push→subscribe | `lib/cascade/cascade_events.ml` | 5 |
| `oas_model_resolve.ml` | move | `lib/cascade/cascade_model_resolve.ml` | 3 |
| `oas_worker_cascade.ml` | move (legacy cascade entry) | `lib/cascade/cascade_legacy_runner.ml` | 3 |
| `oas_worker_named_cascade.ml` | move | `lib/cascade/cascade_oas_runner.ml` | 3 |
| `oas_worker_named_fsm.ml` | move | `lib/cascade/cascade_attempt_fsm.ml` | 3 |
| `oas_worker_named_error.ml` | move | `lib/cascade/cascade_error_classify.ml` | 3 |
| `oas_worker_exec_transport.ml` | move | `lib/cascade/cascade_transport.ml` | 3 |
| `oas_worker_exec.ml` | move (cascade entrypoint) | `lib/cascade/cascade_runner.ml` | 3 |
| `oas_worker_exec_agent.ml` | move | `lib/keeper/keeper_agent_context.ml` | 6 |
| `oas_worker_exec_checkpoint.ml` | move | `lib/keeper/keeper_oas_checkpoint.ml` | 6 |
| `oas_worker_named.ml` (1459 LOC) | **split** A/B/C | A→`lib/agent_sdk_call.ml` augment, B→`lib/cascade/cascade_runner.ml` augment, C→`lib/keeper/keeper_turn_driver.ml` (new) | 4 |

After phase 6: zero `oas_*.ml` files. `lib/oas_*` glob returns empty.
Lint rule added in Phase 7 (CI grep) to prevent reintroduction.

## 6. Migration phases

Each phase is one or more PRs. Each PR is independently revertable.
Build-green hard gate at every PR.

### Phase 1 — RFC + caller inventory freeze (this PR)

- Land this RFC.
- Inventory script: `scripts/rfc-0047-oas-adapter-inventory.sh`.
  - Default mode regenerates `docs/rfc/RFC-0047-caller-inventory.txt`
    and `docs/rfc/RFC-0047-module-graph.dot`.
  - `--check` mode exits non-zero if regenerated output drifts from
    committed baseline. Used by Phase 2-7 PRs as a CI gate.
- Phase 1 baseline (frozen 2026-05-08):
  - **810 inventory entries** (781 code references + 15 doc/markdown +
    14 cross-RFC).
  - Top callers (code): `test/test_oas_worker.ml` (223), `lib/keeper/keeper_error_classify.ml` (82),
    `lib/oas_worker_exec.ml` (44), `test/test_keeper_unified.ml` (40),
    `lib/oas_worker_named.ml` (40 — intra-family coupling).
  - Most-referenced module: `Oas_worker_named` (131 external refs)
    confirms the Phase 4 hotspot.
  - Module graph: 25 cross-domain edges. `oas_worker_named → Cascade_*`
    weighs 77 (largest single edge), `oas_worker_exec → Dashboard_*`
    weighs 8 (push-style violation per Phase 5).
- No code change beyond script + baseline files. Establishes the
  reference against which each subsequent phase verifies "no caller
  surface drift".

### Phase 2 — Clean 3 rename (`oas_*` → `agent_sdk_*`)

**Scope correction (during Phase 2 PR, 2026-05-08).** The original RFC
listed 4 files. Inspection found `lib/oas_worker.ml` is structurally a
**facade** — `include Cascade_runner`, `include Cascade_legacy_runner`,
`include Oas_worker_named` — over three modules that are NOT clean
(Phase 3 / Phase 4 targets). Renaming the facade alone produces an
`Agent_sdk_call` module that still re-exports `Oas_worker_named.run_named`,
i.e. the lie moves but does not disappear. `oas_worker.ml` is deferred
to Phase 4, when its dependents are dissolved.

- Files in scope (3): `oas_response.ml`, `oas_log_bridge.ml`,
  `oas_bus_instrument.ml`. All 3 are self-contained — zero cross-domain
  refs, no `include Oas_*`, only `Agent_sdk.*` external use.
- Renames:
  - `lib/oas_response.ml`(+`.mli`) → `lib/agent_sdk_response.ml`(+`.mli`)
  - `lib/oas_log_bridge.ml`(+`.mli`) → `lib/agent_sdk_log_bridge.ml`(+`.mli`)
  - `lib/oas_bus_instrument.ml`(+`.mli`) → `lib/agent_sdk_metrics_bridge.ml`(+`.mli`)
- Action: `git mv` + caller updates across ~41 references
  (`Agent_sdk_response` 21 + `Agent_sdk_metrics_bridge` 19 + `Agent_sdk_log_bridge` 1).
- Risk: low. Mechanical rename, no behavior change.
- Verification: `dune build`, `dune runtest`, partial-match warning
  count unchanged. Inventory baseline regenerated in same PR — 3 modules
  drop from `lib/oas_*` enumeration; their refs disappear from the
  caller inventory.

### Phase 3 — Cascade extraction (7 files → `lib/cascade/`)

- Files: `oas_worker_cascade.ml`, `oas_worker_named_cascade.ml`,
  `oas_worker_named_fsm.ml`, `oas_worker_named_error.ml`,
  `oas_worker_exec_transport.ml`, `oas_worker_exec.ml`,
  `oas_model_resolve.ml`.
- Action: `git mv` + rename per §5 mapping + caller updates.
- Sub-PRs: split into 2-3 PRs by file batch to keep individual PR
  diffsize under ~600 LOC.
  - PR-3a: 3 leaf files (`*_fsm`, `*_error`, `*_transport`) — no internal
    cross-deps among `oas_*`.
  - PR-3b: 2 entry files (`oas_worker_named_cascade`, `oas_worker_cascade`).
  - PR-3c: 2 capstone files (`oas_worker_exec`, `oas_model_resolve`).
- Risk: medium. ~1500 LOC churn. Existing keeper callers (20 files) must
  follow rename in lockstep.
- Verification: per PR — build, runtest, plus an *additional* check that
  no `lib/cascade/cascade_*.ml` imports `Keeper_*` or `Masc_domain` (the
  new home should not introduce new reverse edges). Where existing
  imports exist, mark with `(* RFC-0047 phase 4: invert *)` for
  follow-up.

### Phase 4 — Hotspot split: `oas_worker_named.ml` (1459 LOC)

- The single largest and most-tangled file. Contains A/B/C concerns
  interleaved within `Oas_worker_named.run`.
- Action: split body into three modules:
  - **A. agent_sdk call sites.** Pure `Agent_sdk.run_loop` invocation
    with prompt + tools + transport. Lands as additions to
    `lib/agent_sdk_call.ml` (Phase 2 rename target).
  - **B. cascade orchestration loop.** Provider rotation, retry,
    exhaustion classification, response acceptance. Lands as
    `lib/cascade/cascade_runner.ml` (extends Phase 3 capstone).
  - **C. keeper turn driver.** Owns `current_turn_observation` updates,
    blocker class stamping, status bridge calls. Lands as new file
    `lib/keeper/keeper_turn_driver.ml`. Existing keeper callers (20
    files) point at `Keeper_turn_driver.run` instead of
    `Oas_worker_named.run`.
- The old `oas_worker_named.ml` becomes a 5-line shim that delegates to
  `Keeper_turn_driver.run` for one PR cycle, then is deleted in the same
  release.
- Risk: high. This is the production-touching path. Mitigation:
  - Pre-PR draft for review by user before merge (no auto-merge).
  - Production canary via cascade `keeper_bound_safe` for 24h after
    merge.
  - Regression test: replay the RFC-0045 production stack trace fixture
    against the new structure to verify the assert is still caught.

### Phase 5 — Event subscribe inversion (2 files)

- Files: `oas_events.ml`, `oas_event_bridge.ml`.
- Currently `oas_events.ml` *pushes* into `Dashboard_oas_bridge`. After
  move to `lib/cascade/cascade_events.ml`, the direction is inverted:
  cascade emits to a typed event stream and dashboard subscribes.
- Action: introduce `Cascade_events.t` typed event variant, add
  subscriber registration in dashboard side
  (`lib/dashboard_*/dashboard_cascade_subscriber.ml`), remove direct
  `Dashboard_oas_bridge.publish_*` calls from the new
  `cascade_events.ml`.
- Risk: medium. Dashboard render must not silently drop events.
- Verification: existing dashboard E2E (if any) + new test
  `test_cascade_event_subscriber_receives_all_variants` with exhaustive
  match on `Cascade_events.t`.

### Phase 6 — Keeper-localized residue (2 files)

- Files: `oas_worker_exec_agent.ml`, `oas_worker_exec_checkpoint.ml`.
  Both small (4 ref / 1 ref), keeper-localized.
- Action: `git mv` to `lib/keeper/keeper_agent_context.ml` and
  `lib/keeper/keeper_oas_checkpoint.ml`. The retained "oas" in the
  checkpoint name is *intentional* — these checkpoints are about
  agent_sdk call resumability, not the OAS-as-prefix family.
- Risk: low.

### Phase 7 — Lint rule + cleanup

- Add CI check: `! ls lib/oas_*.ml 2>/dev/null` must succeed (i.e. no
  `lib/oas_*.ml` exists). Add to `.github/workflows/lint.yml`.
- Add CI check: `! rg -l '^module Oas_' lib/` (no top-level OAS-prefixed
  modules outside agent_sdk repo).
- Update `instructions/software-development.md` with a new entry under
  AI 코드 생성 안티패턴 #5: "OAS prefix in masc-mcp consumer code".
  Reference RFC-0047.
- Update `agent_delegation` subsystem list in `~/me/CLAUDE.md` to
  include cascade/agent_sdk_call as RFC-required scopes.

## 7. Test plan

- **Per-phase build green**: `dune build && dune runtest` on every PR.
- **Caller inventory drift detection**: `scripts/oas-adapter-caller-inventory.sh`
  re-run on every PR; diff against frozen `RFC-0047-caller-inventory.txt`
  must show only expected rename/move changes (no behavior-touching
  diffs). Per-phase delta committed alongside.
- **Module graph regression**: `lib/cascade/*.ml` may not import any
  symbol matching `Keeper_*` or `Masc_*` after Phase 4. Verified by
  `rg '\bKeeper_|\bMasc_' lib/cascade/*.ml | wc -l` returning 0 (or a
  documented per-file allowlist).
- **Production canary**: after Phase 4 merge, run a single
  `keeper_bound_safe` for 24h and confirm zero new asserts/regressions
  via Prometheus `keeper_assert_failure_total` counter.
- **RFC-0045 regression fixture**: existing 4 tests in
  `test_keeper_registry.ml` `rfc_0045_sdk_turn_boundary` group must
  continue to pass after Phase 4 (the file split must not change the
  invariant).

## 8. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Phase 4 introduces silent behavior drift | Medium | High (prod) | Production canary + RFC-0045 regression fixture |
| Concurrent keeper sub-lib extraction creates merge conflict storm | High | Medium (rebase pain) | Serialize: this RFC's Phase 4 lands BEFORE keeper sub-lib work resumes |
| Phase 3 rename breaks downstream consumers (test/bin) | Medium | Low (caught by CI) | Codemod script + per-PR caller inventory diff |
| Aspirational naming reintroduced by future PR | High | Medium (anti-learning) | Phase 7 CI lint + RFC reference in PR template |
| Phase 5 dashboard event subscriber misses a variant | Low | Medium (silent drop) | Exhaustive match test against `Cascade_events.t` |
| Total LOC churn (~4400) saturates review bandwidth | High | Medium | 9-11 PRs across multiple weeks; no single PR > 600 LOC except Phase 4 hotspot split |

## 9. Open questions

1. Should Phase 2 also rename the `.opam` package name visible to
   downstream consumers? (Currently masc-mcp does not export these.) —
   *Tentative answer*: No. Keep package surface unchanged.
2. Phase 4 introduces `lib/keeper/keeper_turn_driver.ml`. Does this
   interact with the existing `lib/keeper/keeper_unified_turn.ml`? — Need
   to inspect during Phase 4 design; possibly merge or refactor that
   file at the same time.
3. Phase 5 inversion (push→subscribe). Is there an existing event bus
   (`Masc_event_bus`) we should reuse, or do we want a typed
   cascade-only stream? — *Recommendation*: typed cascade-only stream
   (`Cascade_events.t`), with a thin adapter to `Masc_event_bus` for
   legacy consumers.
4. Should the RFC-0046 FsmHub work resume before Phase 4? — Both touch
   keeper observation. *Recommendation*: let RFC-0046 finish current
   step (Step 1+2 already merged in #14226) before starting Phase 4 to
   reduce conflict surface.

## 10. Stop conditions

If at any phase the following triggers, halt and reassess via a
follow-up RFC:

- Caller inventory diff exceeds 50 unrelated drift entries (suggests
  hidden coupling not visible from rg).
- Phase 4 production canary surfaces any new assert or unexplained
  status drift in 24h window.
- A reverse-direction import emerges that cannot be resolved by
  dependency inversion (e.g. cascade fundamentally needs keeper
  identity). At that point the layering model itself is wrong and
  needs revision.

## 11. Migration completion criteria

- `ls lib/oas_*.ml` returns empty.
- `lib/cascade/*.ml` does not import `Keeper_*` or `Masc_domain`.
- `lib/agent_sdk_call.ml` does not import `Keeper_*`, `Cascade_*`,
  `Masc_*`, `Dashboard_*`.
- CI lint rules from Phase 7 active.
- All 504 references migrated (verified by inventory).
- Production canary passes.
- This RFC's Status updated to "Implemented".

## 12. Appendix — what is NOT in scope

- **Splitting `agent_sdk` itself.** OAS repo is already clean (0 MASC
  refs). No changes to `~/me/workspace/yousleepwhen/oas`.
- **Dune sub-library introduction.** Single `masc_mcp` library retained.
  Sub-library conversion is a separate RFC if/when desired.
- **Keeper sub-library extraction.** That work is tracked separately
  (memory `project_keeper_sublib_extraction_analysis.md`) and is
  serialized after this RFC completes.
- **Provider behavior changes.** Anthropic/OpenAI/ZAI provider routing,
  retry, and tool execution semantics are byte-identical pre/post.
- **Tool schema redesign.** `Masc_domain.tool_schema` remains the
  consumer-side type; OAS adapter converts to `Agent_sdk.Types.tool`
  internally. A future RFC may unify these.
