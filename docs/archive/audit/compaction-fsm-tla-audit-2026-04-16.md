---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/keeper/keeper_state_machine.ml
  - lib/keeper/keeper_compact_policy.ml
  - specs/keeper-state-machine/KeeperCompactionLifecycle.tla
---

# Compaction FSM ↔ TLA+ Spec Audit (2026-04-16)

**Status**: v2 — TLA+ side enumerated end-to-end, OCaml FSM core verified with direct reads (phases, events, compaction handlers).
**Scope**: Two distinct compactions + three specs that touch them:
- **Context compaction** (token/message reduction) — spec `specs/keeper-state-machine/KeeperContextLifecycle.tla`
- **Memory bank compaction** (note kind-capped pruning) — spec `specs/bug-models/MemoryCompaction.tla`
- **Primary keeper FSM** (12-state lifecycle, includes compaction phases) — spec `specs/keeper-state-machine/KeeperStateMachine.tla`

The prior audit `docs/tla-audit/state-fsm-gap-2026-04-13.md` covers **KeeperStateMachine.tla** and documents the `manual_reconcile_required` drift (see §1.4). This audit complements it by focusing on compaction-specific specs (`KeeperContextLifecycle`, `MemoryCompaction`) and the OAS event surface.

---

## 1. Context Compaction — KeeperContextLifecycle.tla

### 1.1 Spec Inventory (verified by direct read)

- **File**: `specs/keeper-state-machine/KeeperContextLifecycle.tla` (316 lines)
- **CONSTANTS**: `Keepers`, `MaxTurns`, `MaxTokens`, `CompactTarget`, `MaxMessages`, `MaxFailures`
- **VARIABLES** (12): `keeper_phase`, `turn_number`, `context_id`, `context_tokens`, `message_count`, `tool_pairs`, `ckpt_ctx_id`, `ckpt_turn`, `ckpt_valid`, `resume_ctx_id`, `fail_count`, `next_ctx_id`
- **Phases** (TLA+ Phases set, line 51): `{"idle", "running", "compacting", "overflow_retry", "done", "error", "dead"}` — 7 abstract phases

#### Actions (10 total)

| # | Action | Source file:line | Precondition (key) | Post-state change (key) |
|---|--------|------------------|--------------------|-------------------------|
| 1 | `StartTurn(k)` | :93-100 | `phase = "idle"` | `phase := "running"`, `resume_ctx_id := context_id` |
| 2 | `TurnProducesOutput(k)` | :104-112 | `phase = "running"` | `context_tokens++`, `message_count++`, `tool_pairs++` |
| 3 | `TokenBudgetExceeded(k)` | :116-122 | `phase = "running" ∧ tokens > MaxTokens` | `phase := "overflow_retry"` |
| 4 | `StartCompaction(k)` | :127-134 | `phase ∈ {"running","overflow_retry"} ∧ (tokens>MaxTokens ∨ messages≥MaxMessages)` | `phase := "compacting"` |
| 5 | `CompactionCompletes(k)` | :140-150 | `phase = "compacting"` | `tokens := CompactTarget`, `message_count := min(2,mc)`, `context_id UNCHANGED`, `phase := "running"` |
| 6 | `TurnSucceeds(k)` | :154-166 | `phase = "running" ∧ tokens ≤ MaxTokens` | `turn++`, checkpoint saved, `fail_count := 0`, `phase := "idle"` |
| 7 | `TurnFails(k)` | :170-178 | `phase = "running"` | `fail_count++`; `phase := "dead"` if exhausted else `"error"` |
| 8 | `RecoverFromError(k)` | :184-193 | `phase = "error" ∧ ckpt_valid` | restore `context_id`, `turn` from ckpt; `phase := "idle"` |
| 9 | `RecoverFresh(k)` | :198-209 | `phase = "error" ∧ ¬ckpt_valid` | new `context_id`, reset all; `phase := "idle"` |
| 10 | `KeeperDone(k)` | :212-218 | `phase = "idle" ∧ turn ≥ MaxTurns` | `phase := "done"` |

#### Safety Invariants (7)

| Invariant | Line | Property |
|-----------|------|----------|
| `TypeOK` | :74-86 | All variables within declared ranges |
| `ContextIsolation` | :251-253 | ∀ k1≠k2: `context_id[k1] ≠ context_id[k2]` — separate Context.t per keeper |
| `ResumeIdentity` | :259-261 | `running ⇒ resume_ctx_id = context_id` — Agent.resume uses current context |
| `TurnMonotonicity` | :266-268 | `ckpt_valid ⇒ ckpt_turn ≤ turn + 1` |
| `CompactionPairIntegrity` | :273-274 | `tool_pairs ≥ 0` — ToolUse/ToolResult atomic |
| `CheckpointConsistency` | :279-281 | `ckpt_valid ⇒ ckpt_turn ≤ turn + 1` (same as Turn Monotonicity in current model) |
| `BudgetAfterCompaction` | :284-286 | `compacting ⇒ CompactTarget ≤ MaxTokens` |

#### Liveness (3)

| Property | Line | Claim |
|----------|------|-------|
| `CompactionProgress` | :298-301 | `overflow_retry ~> {running, error, done, dead}` |
| `EventualTurnCompletion` | :304-307 | `running ~> {idle, error, done, dead}` |
| `AllKeepersTerminate` | :311-313 | `♦ phase ∈ {done, dead}` |

#### Config (clean)

`specs/keeper-state-machine/KeeperContextLifecycle.cfg`:
```
CONSTANTS: Keepers={dreamer,coder}, MaxTurns=3, MaxTokens=4, CompactTarget=2, MaxMessages=3, MaxFailures=3
INVARIANTS: TypeOK ContextIsolation ResumeIdentity TurnMonotonicity CompactionPairIntegrity CheckpointConsistency BudgetAfterCompaction
PROPERTIES: CompactionProgress EventualTurnCompletion AllKeepersTerminate
```

No `-buggy.cfg` variant present (per `ls specs/keeper-state-machine/`) — **this is itself a gap**. Per `instructions/software-development.md` TLA+ Bug Model pattern, each spec should have a buggy counterpart to prove invariants are strong enough. See §1.4 Known Gaps.

### 1.2 OCaml Implementation Anchors (verified by direct read of worktree)

| Artifact | Location | Content (verified) |
|----------|----------|--------------------|
| Phase sum type | `lib/keeper/keeper_state_machine.mli:20-37` ✓ | 12 constructors: `Offline \| Running \| Failing \| Overflowed \| Compacting \| HandingOff \| Draining \| Paused \| Stopped \| Crashed \| Restarting \| Dead` |
| Event sum type | `lib/keeper/keeper_state_machine.mli:139-` ✓ | 22+ constructors including `Compaction_started`, `Compaction_completed { before_tokens; after_tokens }`, `Compaction_failed { reason }`, `Context_overflow_detected`, `Auto_compact_triggered`, `Operator_compact_requested` |
| `conditions` record | `lib/keeper/keeper_state_machine.mli:48-88` ✓ | 17 boolean fields including `compaction_active`, `context_overflow`, `compact_retry_exhausted`. Phase is **derived** from conditions (Kubernetes pattern). |
| `Compaction_completed` handler | `lib/keeper/keeper_state_machine.ml:374-382` ✓ | Clears 3 fields: `compaction_active:=false; context_overflow:=false; compact_retry_exhausted:=false`. Comment explicitly explains retry-latch release intent. |
| `Compaction_failed` handler | `lib/keeper/keeper_state_machine.ml:383-389` ✓ | Clears only `compaction_active:=false`. Leaves `context_overflow=true` intentionally (comment: overflow unresolved, retry-latch owned by `keeper_unified_turn`). |
| `Turn_succeeded` handler | `lib/keeper/keeper_state_machine.ml:362-363` ✓ | Only `{ c with turn_healthy = true }`. Does **NOT** clear `manual_reconcile_required` — see §1.4 drift note. |
| FSM entry | `lib/keeper/keeper_state_machine.ml` — `transition`, `entry_action` | 12-state FSM with RFC-0002 Det/NonDet layering (per .mli:1-12). |
| Compaction policy | `lib/keeper/keeper_compact_policy.ml` — `compact_if_needed`, gate evaluation | 5 gates (see §1.3 row 4). |
| Compaction execution | `lib/keeper/context_compact_oas.ml` — OAS strategy pipeline wrapper | PruneToolOutputs, MergeContiguous, DropLowImportance, stub_tool_results, repair_broken_tool_call_pairs, sync_oas_context. |
| Checkpoint store | `lib/keeper/keeper_checkpoint_store.ml` — atomic write + auto-prune (keep_recent=3) | Filesystem-first (MASC principle). |
| `compaction_policy` record | `lib/keeper/keeper_types.mli:12-19` ✓ | `{ profile; ratio_gate; message_gate; token_gate; cooldown_sec; max_checkpoint_messages }` |
| `compaction_runtime` record | `lib/keeper/keeper_types.mli:58-65` ✓ | `{ count; last_ts; last_before_tokens; last_after_tokens; last_check_ts; last_decision }` — observability state already staged for Phase 2 retention. |
| Post-turn lifecycle contract | `lib/keeper/keeper_state_machine.mli:110-138` ✓ | **`Compaction_started/_completed/_failed` MUST be dispatched only from `Keeper_post_turn.apply_post_turn_lifecycle`** (synchronous tail of keeper turn). Violating this reopens `KeepalivePhaseConsistency.tla` bug (`NoDrainTransition` / `GhostDispatch` actions catch it). Spec functions as a feature-flag-style guard. |

### 1.3 Traceability Matrix — TLA+ action ↔ OCaml

**Legend**: ✓ verified by direct read, 🔍 identified by first-pass exploration (pending direct re-read), ❓ unverified.

| # | TLA+ action | OCaml function | Key variable changes (code) | Drift? |
|---|-------------|----------------|-----------------------------|--------|
| 1 | `StartTurn(k)` | 🔍 `keeper_agent_run.ml` `run_turn` entry | `phase := Running`, pass `shared_context` to `Agent.resume` | likely OK — `ResumeIdentity` motivated by memory feedback "Context.t identity on resume" |
| 2 | `TurnProducesOutput(k)` | 🔍 `Agent.run` within OAS | tokens/messages accumulate via `sync_oas_context` | OK (conceptual) |
| 3 | `TokenBudgetExceeded(k)` | 🔍 `keeper_unified_turn.ml` (spec comment :115) | Event: `Context_overflow_detected { source = `Prompt_rejected|`Oas_signal; token_count; limit_tokens }` ✓ verified at mli:174-178 | OK — sets `context_overflow:=true` (verified :442-446) |
| 4 | `StartCompaction(k)` | ✓ `keeper_compact_policy.ml` `compact_if_needed` → `Auto_compact_triggered`/`Operator_compact_requested` event | `compaction_active:=true`. `Auto_compact_triggered` handler :447-451 verified; entry action `Start_compaction` at :475, :500 | **ABSTRACTION**: spec's precondition `(tokens>Max ∨ messages≥Max)` abstracts OCaml's 5 gates (ratio/message/token/tool-heavy/cooldown). Spec is sound but not complete. |
| 5 | `CompactionCompletes(k)` | ✓ `keeper_state_machine.ml:374-382` `Compaction_completed _` handler | `compaction_active:=false; context_overflow:=false; compact_retry_exhausted:=false` | **OK** — spec's intent (tokens→CompactTarget, phase→running) aligns with code's condition clearing. Context identity preservation (Spec: `context_id UNCHANGED`) requires separate OAS-level verification (see §1.5 tlc run). |
| 6 | `CompactionFails` (NOT in spec) | ✓ `keeper_state_machine.ml:383-389` `Compaction_failed _ ` handler | only `compaction_active:=false`, `context_overflow` stays true | **SPEC GAP**: TLA+ has no `CompactionFailed` action. OCaml's retry-exhaustion path (`compact_retry_exhausted` latch → `Paused`) is unmodeled. See §1.4 gap 5. |
| 7 | `TurnSucceeds(k)` | ✓ `keeper_state_machine.ml:362-363` `Turn_succeeded` handler | only `{ c with turn_healthy = true }` | **KNOWN DRIFT** (from prior audit `docs/tla-audit/state-fsm-gap-2026-04-13.md` §2.1): `KeeperStateMachine.tla`'s `TurnSucceeded` clears `manual_reconcile_required` (spec line 105), but OCaml `Turn_succeeded` does not. PR #6834 fixed via *separate* `Manual_reconcile_cleared` event dispatch in `keeper_keepalive.ml`, **not** by amending Turn_succeeded handler. Drift persists as "spec-abstraction mismatch" — functional behavior correct, formal mapping asymmetric. |
| 8 | `TurnFails(k)` | 🔍 `Turn_failed { consecutive; max_allowed }` event; `Restart_budget_exhausted` follows | `turn_healthy` derived from `consecutive = 0`. Phase → `Failing` (or `Dead` via `restart_budget_remaining = false`). ✓ handler at :364-366, event at mli:143 | OK structurally; exact Failing vs Dead routing lives in `derive_phase`. |
| 9 | `RecoverFromError(k)` | 🔍 `Agent.resume(?context)` — `agent_checkpoint.ml:build_resume` | restore from checkpoint | OK per memory feedback |
| 10 | `RecoverFresh(k)` | ✓ `Fiber_started` event handler `keeper_state_machine.ml:406-433` | Resets 12 conditions including `compact_retry_exhausted:=false`, `context_overflow:=false`. **Note**: `operator_paused` PRESERVED (not reset). Comment explicitly cites TLA+ model-checking result: "preserving stop_requested across fiber restart causes liveness violation." | **BONUS FINDING**: spec-driven design decision documented in code. |
| 11 | `KeeperDone(k)` | ❓ — likely `derive_phase` rule for `turn_number ≥ MaxTurns` (TLA+ specific; MASC keepers run indefinitely) | No clear OCaml counterpart — spec's `KeeperDone` is a modeling artifact for bounded state-space; MASC keepers loop forever. | **MODELING-ONLY**: acceptable asymmetry. Document as "spec-only terminal for bounded model checking." |

### 1.4 Known Gaps / Potential Drift

1. **Spec abstracts 3 of 5 compaction gates.** TLA+ `StartCompaction` uses only token-budget and message-count preconditions. OCaml `keeper_compact_policy.ml` has 5: `ratio_gate`, `message_gate`, `token_gate`, tool-heavy (`msg_count>40 ∧ ratio>0.15`), `continuity_compaction_cooldown_sec`. **Classification**: acceptable abstraction, but the model cannot prove cooldown/tool-heavy/ratio correctness — those live outside the TLA+ checked properties. Document the model's boundary so operators know which safety claims are formal vs. untested.

2. **No `-buggy.cfg` variant for KeeperContextLifecycle.** Per the TLA+ Bug Model pattern (`instructions/software-development.md`), every spec with safety invariants should have a buggy counterpart proving invariants fail on a known bug. Missing here. **Recommendation**: add `KeeperContextLifecycle-buggy.cfg` that toggles a deliberate bug (e.g., `CompactionCompletes` drops `UNCHANGED <<context_id, resume_ctx_id>>`, expect `ContextIsolation` or `ResumeIdentity` to fail). Separate PR.

3. **Manual-reconcile drift persists as spec-code asymmetry** (verified at `keeper_state_machine.ml:362-363`): TLA+ `KeeperStateMachine.tla:105` models `TurnSucceeded` as directly clearing `manual_reconcile_required`. OCaml's `Turn_succeeded` handler only sets `turn_healthy := true`; clearing happens via a separate `Manual_reconcile_cleared` event dispatched from `keeper_keepalive.ml` (PR #6834). **Classification**: **abstraction mismatch, not live bug** — functional behavior correct as of 2026-04-16 worktree. Action item: either (a) update TLA+ spec to model two events (Turn_succeeded + Manual_reconcile_cleared) accurately, or (b) document the abstraction explicitly and add a `RunningClearsManualReconcile` invariant test that exercises the two-event sequence. Prefer (a) for precision.

4. **`CheckpointConsistency` is duplicate of `TurnMonotonicity`** in current spec (both say `ckpt_valid ⇒ ckpt_turn ≤ turn + 1`). Either consolidate or strengthen one to differentiate (e.g., `ckpt_ctx_id` must reference an allocated context_id, i.e., `ckpt_ctx_id ≤ next_ctx_id`). Minor cleanup PR.

5. **Compaction retry / exhaustion not modeled.** OCaml has `compact_retry_exhausted` latch (verified at `.mli:83-87` and handler behavior at `.ml:383-389`) routing overflow to `Paused` when set. TLA+ `KeeperContextLifecycle.tla` has no `CompactionFailed` action; `CompactionCompletes` always succeeds. **Recommendation**: extend spec with a `CompactionFailed(k)` action transitioning `compacting → overflow_retry` (retry) or `compacting → paused` (latch set). This would enable formal verification of the `Paused` sink property (keeper-observer invariant).

6. **Post-turn lifecycle contract is informal**: `lib/keeper/keeper_state_machine.mli:110-138` states `Compaction_started`/`Handoff_started` must dispatch only from `Keeper_post_turn.apply_post_turn_lifecycle`. Violation reopens `KeepalivePhaseConsistency.tla` bug. **Positive finding**: spec-code coupling is explicit and reviewable. **Recommendation**: add a lint/CI check that greps for `Compaction_started` / `Handoff_started` outside allowed files and fails the build.

### 1.5 Reproduction Commands

`tla2tools.jar` is bundled at `specs/keeper-state-machine/tla2tools.jar`. The repo's canonical script `scripts/tla-check.sh` orchestrates all spec runs with download/caching for CI.

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/specs/keeper-state-machine

# Clean spec
java -XX:+UseParallelGC -Xmx2g -cp tla2tools.jar tlc2.TLC \
  -config KeeperContextLifecycle.cfg -workers 4 -deadlock \
  KeeperContextLifecycle.tla

# (Recommended) Use the repo's script for full-suite runs:
~/me/workspace/yousleepwhen/masc-mcp/scripts/tla-check.sh
```

**Observed runtime (2026-04-16, M3 Max 128GB)**: KeeperContextLifecycle clean run on default cfg reached **Progress(30) with ~5.6M distinct states explored in 13+ minutes, no invariant or property violations observed**; did not complete in session budget. No drift found within the explored state subset. **Recommendation**: for CI, create a reduced `KeeperContextLifecycle-ci.cfg` with `Keepers={"a"}, MaxTurns=2` (state space ~1-2 orders smaller) that completes in <1 min and retain the default cfg for periodic nightly/release validation.

### 1.6 Phase Set Isomorphism (TLA+ vs OCaml — completed)

OCaml phases verified at `lib/keeper/keeper_state_machine.mli:20-37`. TLA+ phases at `KeeperContextLifecycle.tla:51`.

| TLA+ phase (context spec) | OCaml phase | Mapping | Notes |
|--------------------------|-------------|---------|-------|
| `idle` | No direct OCaml phase | **Abstracted** | OCaml doesn't distinguish idle; keepers are either `Running` or in a buffer state. |
| `running` | `Running` | ✓ | Healthy heartbeat loop executing. |
| `compacting` | `Compacting` | ✓ | Spec tracks tokens/messages reduction; OCaml tracks via `compaction_active` condition. |
| `overflow_retry` | `Overflowed` | ✓ | Spec: tokens>Max pending compaction. OCaml: `context_overflow=true AND ¬compact_retry_exhausted`. |
| `error` | `Failing` or `Crashed` | partial | `Failing` = consecutive failures probing recovery; `Crashed` = unrecoverable restart candidate. Spec collapses both. |
| `dead` | `Paused` (latch set) or `Dead` (budget exhausted) | partial | Spec's `dead` = "terminal, cannot recover". OCaml splits into operator-pausable (`Paused`) and budget-exhausted terminal (`Dead`). |
| `done` | (modeling artifact, no OCaml counterpart) | **Spec-only** | Spec uses for bounded model-checking termination; MASC keepers loop indefinitely. |
| — | `Offline` | **Unmodeled** | OCaml-only: registered but no fiber yet. |
| — | `HandingOff` | **Unmodeled** | OCaml-only: generation rollover, separate lifecycle from compaction. |
| — | `Draining` | **Unmodeled** | OCaml-only: graceful shutdown. |
| — | `Stopped` | **Unmodeled** | OCaml-only: terminal clean exit. |
| — | `Restarting` | **Unmodeled** | OCaml-only: supervisor backoff. |

**Summary**: OCaml has 12 phases, spec has 7. **6 phases are OCaml-only** (Offline, HandingOff, Draining, Stopped, Crashed vs Failing distinction, Restarting). This is acceptable because `KeeperContextLifecycle.tla` is a **context-lifecycle sub-spec**, not the full keeper FSM. For full-FSM verification use `KeeperStateMachine.tla` (primary 12-state spec, prior audit in `docs/tla-audit/state-fsm-gap-2026-04-13.md`).

**Recommendation**: add a top-level comment block to `KeeperContextLifecycle.tla:1-12` explicitly stating which OCaml phases are abstracted/omitted, citing `keeper_state_machine.mli:20-37` as the full-state reference. This makes the spec's boundary self-documenting.

---

## 2. Memory Bank Compaction — MemoryCompaction.tla

### 2.1 Spec Inventory (verified by direct read)

- **File**: `specs/bug-models/MemoryCompaction.tla` (200 lines)
- **Purpose**: Models `keeper_memory_bank.ml` `compact_memory_bank_if_needed` (NOT context compaction)
- **Target code**: `lib/keeper/keeper_memory_bank.ml:292-448`, `lib/keeper/keeper_memory_policy.ml:131-148` (kind_caps)
- **CONSTANTS**: `TargetNotes`, `ConstraintCap`, `LongTermCap`
- **VARIABLES**: `bank` (seq of notes), `result` (compacted seq), `phase` (`"accumulating"|"compacting"|"done"`)
- **Kinds** (line 28): `{"constraint", "decision", "progress", "long_term"}` with priorities 90/86/66/95 respectively

#### Actions

| Action | Precondition | Effect |
|--------|--------------|--------|
| `AppendConstraint` (:47-51) | `phase="accumulating" ∧ Len(bank)<TargetNotes*2` | append note kind=constraint, pri=90 |
| `AppendDecision` (:53-57) | same | pri=86 |
| `AppendProgress` (:59-63) | same | pri=66 |
| `AppendLongTerm` (:65-69) | same | pri=95 |
| `TriggerCompaction` (:73-77) | `Len(bank) > TargetNotes` | `phase := "compacting"` |
| `SafeCompact` (:83-118) | `phase="compacting"` | kind-capped select + fallback fill; models `keeper_memory_bank.ml:407-408` |
| `BugPriorityOnlyCompact` (:122-141) | same | priority-only select — **bug model** |

#### Safety Invariants (5)

| Invariant | Line | Property |
|-----------|------|----------|
| `ConstraintsPreserved` | :162-167 | `done ⇒ count(result, constraint) ≥ min(count(bank, constraint), ConstraintCap)` |
| `NeverEmpty` | :170-171 | `done ∧ Len(bank)>0 ⇒ Len(result)>0` |
| `ResultBounded` | :174-175 | `done ⇒ Len(result) ≤ TargetNotes` |
| `LongTermProtected` | :179-184 | constraint-analog for `long_term` kind |
| `RecentFloorRespected` | :193-197 | `done ⇒ Len(result) ≥ min(Len(bank), TargetNotes)` |

#### Specs (clean + buggy)

- `SpecSafe ≜ Init ∧ □[NextSafe]_vars` (line 155)
- `SpecBuggy ≜ Init ∧ □[NextBuggy]_vars` (line 156)

#### Configs

- `specs/bug-models/MemoryCompaction.cfg`: `SPECIFICATION Spec` (→ SafeCompact only)
  - INVARIANT: all 5 above
  - CONSTANTS: `TargetNotes=8, ConstraintCap=2, LongTermCap=3`
  - **Expected**: "No error"
- `specs/bug-models/MemoryCompaction-buggy.cfg` (not yet read but exists per Glob)
  - **Expected**: invariant violated (priority-only select starves constraints when `Len(long_term) > TargetNotes - LongTermCap`)

### 2.2 OCaml Implementation Anchors

| Artifact | Location |
|----------|----------|
| `compact_memory_bank_if_needed` | `lib/keeper/keeper_memory_bank.ml:292-448` (per TLA+ comment) |
| `kind_caps` | `lib/keeper/keeper_memory_policy.ml:131-148` (per TLA+ comment) |
| Fallback fill (`ignore_kind_cap:true`) | `lib/keeper/keeper_memory_bank.ml:407-408` (per TLA+ comment) |
| Recent floor | OCaml: `let recent_floor = max 16 (min 64 (target_notes / 5))` (per TLA+ comment :187-189) |

### 2.3 Known Drift

Cannot determine without direct read of `keeper_memory_bank.ml`. The spec's TLA+ comments cite specific lines; verification requires confirming those lines still contain the stated logic and that kind_caps values (2/2/?/3 — decisions cap reuses ConstraintCap in spec, line 96-98) match OCaml.

**Follow-up items**:
1. Read `lib/keeper/keeper_memory_policy.ml:131-148` → confirm kind_caps exact values → update spec CONSTANTS if OCaml changed.
2. Read `lib/keeper/keeper_memory_bank.ml:292-448` → confirm compaction algorithm matches `SafeCompact` action (priority-capped select + fallback fill).
3. Run `tlc MemoryCompaction.tla -config MemoryCompaction.cfg` (clean) and `-config MemoryCompaction-buggy.cfg` (buggy) → confirm clean passes + buggy fails.

### 2.4 Reproduction Commands + Observed Results

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/specs/bug-models

# Buggy — expect "Invariant X is violated"
java -XX:+UseParallelGC -Xmx2g -cp ../keeper-state-machine/tla2tools.jar tlc2.TLC \
  -config MemoryCompaction-buggy.cfg -workers 4 -deadlock \
  MemoryCompaction.tla

# Clean — expect "No error" (long-running, see below)
java -XX:+UseParallelGC -Xmx2g -cp ../keeper-state-machine/tla2tools.jar tlc2.TLC \
  -config MemoryCompaction.cfg -workers 4 -deadlock \
  MemoryCompaction.tla
```

**Observed results (2026-04-16, M3 Max 128GB)**:

| Run | Result | Evidence |
|-----|--------|----------|
| `MemoryCompaction-buggy.cfg` | ✓ **Invariant `LongTermProtected` violated** (as expected) | `Error: Invariant LongTermProtected is violated. Error: The behavior up to this point is:` at 1,472,782 states / depth 12 / 13s. TTrace file `MemoryCompaction_TTrace_<ts>.tla` generated. |
| `MemoryCompaction.cfg` (clean) | ⏳ Did not complete in session | State space explosion — concurrent accumulation orderings generate millions of states. **Recommendation**: similar CI-focused `MemoryCompaction-ci.cfg` with smaller `TargetNotes` to bound exploration. |

**What the buggy violation proves**: the priority-only select strategy (models a broken implementation) allows 8 constraint notes + 1 long_term to dominate the result, starving ConstraintCap=2 respect **AND** reducing long_term below LongTermCap=3 (only 1 retained when bank has 2+). TLC picks up the LongTermProtected invariant as the first invariant to fail; ConstraintsPreserved / RecentFloorRespected may also be violated on other paths — not explored because TLC stops at first violation.

---

## 3. Summary

### What's verified
- Both TLA+ specs exist: `specs/keeper-state-machine/KeeperContextLifecycle.tla` (context compaction) and `specs/bug-models/MemoryCompaction.tla` (memory bank) with buggy cfg at `bug-models/MemoryCompaction-buggy.cfg`.
- OAS `event_bus.ml` already emits `ContextCompactStarted` and `ContextCompacted` payloads (via `lib/event_bus.mli:42-45, 34-35`). Since OAS 0.136.0.
- OAS `hooks.mli` has `pre_compact` hook but no `post_compact` (gap confirmed at `hooks.mli:79-83, 136`).
- OCaml 12-phase FSM verified at `keeper_state_machine.mli:20-37`. Event sum type verified at `.mli:139+`.
- `Compaction_completed` handler cleanly clears 3 fields (`.ml:374-382`). `Compaction_failed` handler is intentionally partial (keeps `context_overflow=true`, `.ml:383-389`).
- **Manual-reconcile drift is abstraction mismatch, not live bug** — PR #6834 fixed via separate event dispatch path; Turn_succeeded handler itself remains unchanged.
- `compaction_policy` + `compaction_runtime` records in `keeper_types.mli:12-65` are pre-staged for Phase 2 retention.
- Post-turn lifecycle contract (`keeper_state_machine.mli:110-138`) explicitly cites `KeepalivePhaseConsistency.tla` as feature-flag-style guard — spec-code coupling is rigorous.

### What needs follow-up (ordered by value)

1. **Create CI-sized cfg variants** (`*-ci.cfg` with Keepers=1/MaxTurns=2 for context spec; smaller TargetNotes for memory bank) → enable full clean-spec checks in every CI build. Default cfg reserved for nightly/release.
2. **Direct read of `lib/keeper/keeper_memory_bank.ml:292-448`** + `keeper_memory_policy.ml:131-148` → confirm spec/code alignment for memory bank compaction. Spec comments cite specific line ranges — easy cross-check.
3. **Propose `KeeperContextLifecycle-buggy.cfg`** → close §1.4 gap 2. Deliberate bug candidate: drop `UNCHANGED <<context_id, resume_ctx_id>>` in `CompactionCompletes` and expect `ContextIsolation`/`ResumeIdentity` violation.
4. **Propose `CompactionFailed(k)` action** in `KeeperContextLifecycle.tla` → close §1.4 gap 5. Models OCaml's retry-exhaustion path.
5. **Update TLA+ `TurnSucceeded`** in `KeeperStateMachine.tla` (primary spec, not context spec) to model two-event sequence (Turn_succeeded + Manual_reconcile_cleared) → close §1.4 gap 3.
6. **Add lint/CI check** for `Compaction_started|Handoff_started` dispatch points → prevent `KeepalivePhaseConsistency.tla` regression (§1.4 gap 6).
7. **Document abstraction boundary** at top of `KeeperContextLifecycle.tla` → self-documenting spec scope (link to §1.6 of this doc).

### Out of scope
- Fixing identified drift: this audit discovers, a separate PR fixes each item.
- Adding `post_compact` hook to OAS: Phase 1 scope.
- MASC subscriber + retention: Phase 2 scope.
- Lifecycle doc: Phase 3 scope (depends on Phase 1+2).

---

**Audit author**: Claude (Opus 4.6)
**Date**: 2026-04-16
**Verified files**: TLA+ specs read end-to-end; `keeper_types.mli` read; OAS `event_bus.mli` + `hooks.mli` read via separate track.
**Unverified anchors**: marked 🔍 (first-pass exploration claim) or ❓ (not verified in this pass).
