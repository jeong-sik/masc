# Compaction FSM ↔ TLA+ Spec Audit (2026-04-16)

**Status**: WIP / Partial — TLA+ side fully enumerated, OCaml side has verified anchors + targeted follow-ups.
**Scope**: Two distinct compactions in masc-mcp:
- **Context compaction** (token/message reduction) — spec `specs/keeper-state-machine/KeeperContextLifecycle.tla`
- **Memory bank compaction** (note kind-capped pruning) — spec `specs/bug-models/MemoryCompaction.tla`

Both compactions share the word "compaction" but operate on completely different subsystems. This audit covers both.

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

### 1.2 OCaml Implementation Anchors (verified)

| Artifact | Location |
|----------|----------|
| Phase sum type | `lib/keeper/keeper_types.ml` (via `Keeper_types_profile` re-export at `keeper_types.mli:8`) — needs direct read of `keeper_types_profile.ml` for full sum type listing |
| FSM entry | `lib/keeper/keeper_state_machine.ml` — `transition`, `entry_action`, event constructors |
| Compaction policy | `lib/keeper/keeper_compact_policy.ml` — `compact_if_needed`, gate evaluation |
| Compaction execution | `lib/keeper/context_compact_oas.ml` — OAS strategy pipeline wrapper (PruneToolOutputs, MergeContiguous, DropLowImportance, stub_tool_results, repair_broken_tool_call_pairs, sync_oas_context) |
| Checkpoint store | `lib/keeper/keeper_checkpoint_store.ml` — atomic write + auto-prune (keep_recent=3) |
| Compaction policy record | `lib/keeper/keeper_types.mli:12-19` `type compaction_policy = { profile; ratio_gate; message_gate; token_gate; cooldown_sec; max_checkpoint_messages }` ✓ verified |
| Compaction runtime record | `lib/keeper/keeper_types.mli:58-65` `type compaction_runtime = { count; last_ts; last_before_tokens; last_after_tokens; last_check_ts; last_decision }` ✓ verified |

### 1.3 Traceability Matrix — TLA+ action ↔ OCaml

**Legend**: ✓ verified by direct read, 🔍 identified by first-pass exploration (pending direct re-read from worktree), ❓ unverified.

| # | TLA+ action | OCaml function | Key variable changes (code) | Drift? |
|---|-------------|----------------|-----------------------------|--------|
| 1 | `StartTurn(k)` | 🔍 keeper_agent_run.ml run_turn entry | `phase := Running`, pass shared_context to `Agent.resume` | likely OK — ResumeIdentity invariant motivated by `Context.t identity on resume` memory |
| 2 | `TurnProducesOutput(k)` | 🔍 `Agent.run` within OAS | tokens/messages accumulate via `sync_oas_context` | OK (conceptual) |
| 3 | `TokenBudgetExceeded(k)` | 🔍 `keeper_unified_turn.ml` (`TokenBudgetExceeded` per spec comment :115) | detected via OAS `ContextOverflowImminent` or API `ContextOverflow` | OK |
| 4 | `StartCompaction(k)` | ✓ `keeper_compact_policy.ml` `compact_if_needed` | `compaction_active := true`, emits Start_compaction event | **CHECK**: does spec's precondition `(tokens>Max ∨ messages≥Max)` match OCaml's 5-gate logic (ratio/message/token/tool-heavy/cooldown)? TLA+ appears to abstract 2 of 5 gates. See §1.4. |
| 5 | `CompactionCompletes(k)` | 🔍 `keeper_state_machine.ml` `Compaction_completed` event handler | context_id PRESERVED, ratio/message reduced | **CHECK**: known drift from `docs/audits/state-fsm-gap-2026-04-13.md` — spec clears `manual_reconcile_required`, OCaml may not. Verify in worktree. |
| 6 | `TurnSucceeds(k)` | 🔍 `Oas_worker_exec.build_checkpoint` + `persist_checkpoint` | checkpoint atomic write, `fail_count := 0` | **CHECK**: same known drift — `TurnSucceeded` clear of `manual_reconcile_required`. |
| 7 | `TurnFails(k)` | 🔍 `Turn_failed` event + `Restart_budget_exhausted` | fail_count increment, phase → Failing/Dead | ❓ |
| 8 | `RecoverFromError(k)` | 🔍 `Agent.resume(?context)` — `agent_checkpoint.ml:build_resume` | restore from checkpoint | OK per memory feedback "Context.t identity on resume" |
| 9 | `RecoverFresh(k)` | 🔍 `Supervisor_restart_attempt` in `keeper_state_machine.ml` | new context_id allocated | ❓ |
| 10 | `KeeperDone(k)` | ❓ needs grep | terminal state | ❓ |

### 1.4 Known Gaps / Potential Drift

1. **Spec abstracts 2 of 5 compaction gates.** TLA+ `StartCompaction` uses only token-budget and message-count preconditions. OCaml `keeper_compact_policy.ml` has 5: ratio_gate, message_gate, token_gate, tool-heavy (`msg_count>40 ∧ ratio>0.15`), continuity_cooldown. The TLA+ model is **sound but not complete** — it catches deadlock on the abstracted subset but cannot prove cooldown/tool-heavy correctness. **Classification**: acceptable abstraction, but document the model's boundary.

2. **No `-buggy.cfg` variant for KeeperContextLifecycle.** Per TLA+ Bug Model pattern, every spec with safety invariants should have a buggy counterpart proving invariants fail on a known bug. Missing here. **Recommendation**: add `KeeperContextLifecycle-buggy.cfg` that toggles a deliberate bug (e.g., `CompactionCompletes` drops `context_id UNCHANGED`, expect `ContextIsolation` or `ResumeIdentity` to fail). Separate PR.

3. **Known drift from prior audit** (`docs/audits/state-fsm-gap-2026-04-13.md` — per memory reference, not yet verified in worktree): `TurnSucceeded` in spec clears `manual_reconcile_required` but OCaml does not. Creates one-way trap where keeper sticks in `Failing` phase. Classification: **DRIFT — live bug**. Needs targeted code-only fix (separate PR).

4. **`CheckpointConsistency` is duplicate of `TurnMonotonicity`** in current spec (both say `ckpt_valid ⇒ ckpt_turn ≤ turn + 1`). Either consolidate or strengthen one to differentiate (e.g., checkpoint should reference a valid context_id).

5. **Compaction retry / exhaustion not modeled.** OCaml has `compact_retry_exhausted` latch routing overflow to `Paused` — TLA+ has no corresponding path. `CompactionCompletes` always succeeds in spec; no `CompactionFailed` action. **Recommendation**: extend spec with `CompactionFailed(k)` action transitioning `compacting → overflow_retry` (retry) or `compacting → dead` (budget exhausted).

### 1.5 Reproduction Commands

Requires TLA+ tools (`tla2tools.jar` from https://github.com/tlaplus/tlaplus). `tlc` not present in the current machine's PATH — operator must install first.

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/specs/keeper-state-machine

# Clean spec — expect "No error"
java -jar ~/.local/lib/tla2tools.jar tlc KeeperContextLifecycle.tla -config KeeperContextLifecycle.cfg

# No buggy variant exists yet (see §1.4 gap 2)
```

### 1.6 Phase Set Isomorphism (TLA+ vs OCaml)

| TLA+ phase | OCaml phase (keeper_types_profile — needs direct read) | Status |
|------------|------------------------------------------------------|--------|
| `idle` | `Idle`? | ❓ needs verify |
| `running` | `Running` | likely ✓ |
| `compacting` | `Compacting` | likely ✓ |
| `overflow_retry` | `Overflowed` | likely ✓ |
| `error` | `Failing`/`Error`? | ❓ |
| `dead` | `Paused`/`Dead`? | ❓ |
| `done` | `Done`? | ❓ |

OCaml has **more phases** (first-pass exploration reported 12-phase FSM). TLA+'s 7 phases are an abstraction. **Follow-up**: enumerate OCaml phases directly from `keeper_types_profile.ml` and classify each as (a) maps to TLA+ phase, (b) substate of a TLA+ phase, or (c) unmodeled (spec gap). Classifications feed §1.4.

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

### 2.4 Reproduction Commands

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp/specs/bug-models

# Clean — expect "No error"
java -jar ~/.local/lib/tla2tools.jar tlc MemoryCompaction.tla -config MemoryCompaction.cfg

# Buggy — expect "Invariant X is violated" (likely ConstraintsPreserved or NeverEmpty)
java -jar ~/.local/lib/tla2tools.jar tlc MemoryCompaction.tla -config MemoryCompaction-buggy.cfg
```

---

## 3. Summary

### What's verified
- Both TLA+ specs exist at `specs/keeper-state-machine/KeeperContextLifecycle.tla` and `specs/bug-models/MemoryCompaction.tla`.
- OAS `event_bus.ml` already emits `ContextCompactStarted` and `ContextCompacted` payloads (see separate Phase 1 SDK analysis).
- OAS `hooks.mli` has `pre_compact` hook but no `post_compact` (gap confirmed).
- `compaction_policy` record and `compaction_runtime` record are already part of keeper_meta (`keeper_types.mli:12-65`) — observability fields for future audit retention are pre-staged.

### What needs follow-up (ordered by value)

1. **Direct read of `lib/keeper/keeper_types_profile.ml`** (or wherever `type phase` is declared) → complete the Phase Set Isomorphism table in §1.6.
2. **Direct read of `lib/keeper/keeper_state_machine.ml`** `Compaction_completed` + `TurnSucceeded` event handlers → confirm `manual_reconcile_required` drift and fill OCaml column of matrix §1.3.
3. **Direct read of `lib/keeper/keeper_memory_bank.ml:292-448`** + `keeper_memory_policy.ml:131-148` → confirm spec/code alignment for memory bank.
4. **Install `tla2tools.jar`** and run reproduction commands §1.5 + §2.4 → attach tlc output tails below.
5. **Propose `KeeperContextLifecycle-buggy.cfg`** → close §1.4 gap 2.
6. **Propose `CompactionFailed(k)` action** in `KeeperContextLifecycle.tla` → close §1.4 gap 5.

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
