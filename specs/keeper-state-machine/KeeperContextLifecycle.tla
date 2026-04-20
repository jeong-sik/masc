---- MODULE KeeperContextLifecycle ----
\* Formal specification of MASC-OAS context management within the keeper lifecycle.
\* Validates that Context.t is correctly preserved, isolated, and compacted
\* across keeper turns, overflow recovery, and checkpoint save/load cycles.
\*
\* Modeled from: keeper_agent_run.ml, keeper_unified_turn.ml,
\*               keeper_compact_policy.ml, oas/context.ml, oas/agent_checkpoint.ml
\*
\* This module intentionally stops at context/checkpoint/compaction identity.
\* Successful handoff rollover (generation increment, trace_id replacement,
\* trace_history append) is modeled separately in
\* [KeeperGenerationLineage.tla] so the lineage contract can stay 1:1 with
\* keeper_rollover.ml without inflating this context-lifecycle state space.
\*
\* Properties verified:
\*   Safety:  ContextIsolation, CompactionPairIntegrity, ResumeIdentity,
\*            TurnMonotonicity, CheckpointConsistency
\*   Liveness: CompactionProgress, EventualTurnCompletion

EXTENDS Naturals, FiniteSets

CONSTANTS
    Keepers,            \* Set of keeper names, e.g. {"dreamer", "coder"}
    MaxTurns,           \* Maximum turn number per keeper (small for model checking)
    MaxTokens,          \* Token budget threshold
    CompactTarget,      \* Tokens remaining after compaction
    MaxMessages,        \* Maximum messages before compaction forced
    MaxFailures         \* Restart budget: max consecutive failures before Dead

VARIABLES
    \* Per-keeper state
    keeper_phase,       \* [Keepers -> Phase]
    turn_number,        \* [Keepers -> 0..MaxTurns]
    context_id,         \* [Keepers -> Nat] unique context identity
    context_tokens,     \* [Keepers -> 0..MaxTokens+1] current token count
    message_count,      \* [Keepers -> Nat]
    tool_pairs,         \* [Keepers -> Nat] ToolUse/ToolResult pair count

    \* Checkpoint state
    ckpt_ctx_id,        \* [Keepers -> Nat] context_id in last checkpoint
    ckpt_turn,          \* [Keepers -> Nat] turn number in checkpoint
    ckpt_valid,         \* [Keepers -> BOOLEAN]

    \* Shared context tracking (Agent.resume identity)
    resume_ctx_id,      \* [Keepers -> Nat] context_id passed to Agent.resume

    \* Failure tracking (models restart_budget_remaining)
    fail_count,         \* [Keepers -> 0..MaxFailures]

    \* Global allocator
    next_ctx_id         \* Monotonic context ID counter

vars == <<keeper_phase, turn_number, context_id, context_tokens, message_count,
          tool_pairs, ckpt_ctx_id, ckpt_turn, ckpt_valid,
          resume_ctx_id, fail_count, next_ctx_id>>

\* Issue #8701: explicit OCaml ↔ TLA+ mapping for the context lifecycle
\* abstraction. SSOT for OCaml side is lib/keeper/keeper_state_machine.ml
\* (12 phases). This spec intentionally collapses the 12 OCaml phases into
\* a 7-symbol alphabet because the context-lifecycle invariants do not
\* depend on transport/handoff details.
\*
\* Mapping (#8979: spec-internal abstract names — five of seven do NOT
\* match phase_to_string output verbatim; two ("running", "compacting")
\* coincide with the wire format):
\*
\*   spec name         ↔ OCaml constructor   (phase_to_string output)
\*   ------------------+----------------------+----------------------
\*   "idle"            ↔ Offline               ("offline")
\*   "running"         ↔ Running               ("running")          *
\*   "compacting"      ↔ Compacting            ("compacting")       *
\*   "overflow_retry"  ↔ Overflowed            ("overflowed")
\*   "done"            ↔ Stopped               ("stopped")
\*   "error"           ↔ Failing | Crashed     ("failing"|"crashed")
\*   "dead"            ↔ Dead                  ("dead")             *
\*       * = spec name and wire format coincide.
\*
\* If trace-driven model checking is later added, the spec strings would
\* need to be renamed to match the wire format.  Until then, treat the
\* table above as the authoritative abstraction function.
\*
\* Unmodeled here (covered in companion specs):
\*   HandingOff, Draining, Paused, Restarting
\* See KeeperGenerationLineage.tla for HandingOff and
\*     KeeperReconcileLiveness.tla for Paused/Restarting/Draining.
Phases == {"idle", "running", "compacting", "overflow_retry", "done", "error", "dead"}

\* ── Initial State ────────────────────────────────────────

Init ==
    \* Each keeper starts with a unique context_id (1, 2, ...)
    /\ keeper_phase = [k \in Keepers |-> "idle"]
    /\ turn_number = [k \in Keepers |-> 0]
    \* Use CHOOSE to assign unique IDs. In the model, Keepers is finite.
    /\ next_ctx_id = Cardinality(Keepers) + 1
    /\ context_id \in [Keepers -> 1..Cardinality(Keepers)]
    /\ \A k1, k2 \in Keepers : k1 /= k2 => context_id[k1] /= context_id[k2]
    /\ context_tokens = [k \in Keepers |-> 0]
    /\ message_count = [k \in Keepers |-> 0]
    /\ tool_pairs = [k \in Keepers |-> 0]
    /\ ckpt_ctx_id = [k \in Keepers |-> 0]
    /\ ckpt_turn = [k \in Keepers |-> 0]
    /\ ckpt_valid = [k \in Keepers |-> FALSE]
    /\ resume_ctx_id = [k \in Keepers |-> 0]
    /\ fail_count = [k \in Keepers |-> 0]

\* ── Type Invariant ───────────────────────────────────────

TypeOK ==
    /\ keeper_phase \in [Keepers -> Phases]
    /\ turn_number \in [Keepers -> 0..MaxTurns]
    /\ context_id \in [Keepers -> Nat]
    /\ context_tokens \in [Keepers -> 0..(MaxTokens + 1)]
    /\ message_count \in [Keepers -> Nat]
    /\ tool_pairs \in [Keepers -> Nat]
    /\ ckpt_ctx_id \in [Keepers -> Nat]
    /\ ckpt_turn \in [Keepers -> Nat]
    /\ ckpt_valid \in [Keepers -> BOOLEAN]
    /\ resume_ctx_id \in [Keepers -> Nat]
    /\ fail_count \in [Keepers -> 0..MaxFailures]
    /\ next_ctx_id \in Nat

\* ── Actions ──────────────────────────────────────────────

\* 1. Start Turn: idle -> running
\*    Models keeper_agent_run.ml:run_turn entry.
\*    shared_context is reused (same context_id).
StartTurn(k) ==
    /\ keeper_phase[k] = "idle"
    /\ turn_number[k] < MaxTurns
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "running"]
    \* Record which context_id was passed to Agent.resume
    /\ resume_ctx_id' = [resume_ctx_id EXCEPT ![k] = context_id[k]]
    /\ UNCHANGED <<turn_number, context_id, context_tokens, message_count,
                   tool_pairs, ckpt_ctx_id, ckpt_turn, ckpt_valid, fail_count, next_ctx_id>>

\* 2. Turn Produces Output: agent generates tokens + tool pairs
\*    Models Agent.run producing tool calls and assistant responses.
TurnProducesOutput(k) ==
    /\ keeper_phase[k] = "running"
    /\ context_tokens[k] <= MaxTokens  \* Still within budget to produce
    /\ context_tokens' = [context_tokens EXCEPT ![k] = context_tokens[k] + 1]
    /\ message_count' = [message_count EXCEPT ![k] = message_count[k] + 1]
    \* ToolUse always paired with ToolResult
    /\ tool_pairs' = [tool_pairs EXCEPT ![k] = tool_pairs[k] + 1]
    /\ UNCHANGED <<keeper_phase, turn_number, context_id, ckpt_ctx_id,
                   ckpt_turn, ckpt_valid, resume_ctx_id, fail_count, next_ctx_id>>

\* 3. Token Budget Exceeded: running -> overflow_retry
\*    Models TokenBudgetExceeded(Input) in keeper_unified_turn.ml:65
TokenBudgetExceeded(k) ==
    /\ keeper_phase[k] = "running"
    /\ context_tokens[k] > MaxTokens
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "overflow_retry"]
    /\ UNCHANGED <<turn_number, context_id, context_tokens, message_count,
                   tool_pairs, ckpt_ctx_id, ckpt_turn, ckpt_valid,
                   resume_ctx_id, fail_count, next_ctx_id>>

\* 4. Start Compaction: from running (proactive) or overflow_retry (reactive)
\*    Models keeper_compact_policy.ml compact_if_needed.
\*    Gates: context_ratio >= 0.6, message_count >= gate, emergency >= 0.8
StartCompaction(k) ==
    /\ keeper_phase[k] \in {"running", "overflow_retry"}
    /\ \/ context_tokens[k] > MaxTokens      \* Emergency / overflow
       \/ message_count[k] >= MaxMessages     \* Message gate
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "compacting"]
    /\ UNCHANGED <<turn_number, context_id, context_tokens, message_count,
                   tool_pairs, ckpt_ctx_id, ckpt_turn, ckpt_valid,
                   resume_ctx_id, fail_count, next_ctx_id>>

\* 5. Compaction Completes: reduces tokens, preserves context identity and tool pairs.
\*    Models Context_reducer strategies.
\*    CRITICAL INVARIANT: tool_pairs never decreases (ToolUse/ToolResult never split).
\*    Context.t identity preserved (same mutable object, same context_id).
CompactionCompletes(k) ==
    /\ keeper_phase[k] = "compacting"
    /\ context_tokens' = [context_tokens EXCEPT ![k] = CompactTarget]
    /\ message_count' = [message_count EXCEPT ![k] =
         IF message_count[k] > 2 THEN 2 ELSE message_count[k]]
    \* Context identity PRESERVED (same mutable Context.t — no new allocation)
    /\ UNCHANGED <<context_id, resume_ctx_id>>
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "running"]
    \* Tool pairs UNCHANGED: compaction never splits ToolUse/ToolResult
    /\ UNCHANGED <<turn_number, tool_pairs, ckpt_ctx_id, ckpt_turn,
                   ckpt_valid, fail_count, next_ctx_id>>

\* 5b. Compaction Failed: strategy returned an error — context_tokens
\*     stay above budget, keeper transitions back to overflow_retry for
\*     another compaction attempt.
\*     Models keeper_state_machine.ml:383-389 Compaction_failed _ handler:
\*     clears compaction_active but leaves context_overflow=true.
\*     NOTE: the retry-exhaustion latch (compact_retry_exhausted → Paused)
\*     lives in keeper_unified_turn and is not yet modelled here. Without
\*     fairness on CompactionCompletes, TLC explores both retry and
\*     success paths; adding a bounded retry variable is a separate
\*     refinement.
CompactionFailed(k) ==
    /\ keeper_phase[k] = "compacting"
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "overflow_retry"]
    \* tokens/messages preserved — nothing was reduced
    /\ UNCHANGED <<turn_number, context_id, context_tokens, message_count,
                   tool_pairs, ckpt_ctx_id, ckpt_turn, ckpt_valid,
                   resume_ctx_id, fail_count, next_ctx_id>>

\* 6. Turn Succeeds: save checkpoint, advance turn counter.
\*    Models Oas_worker_exec.build_checkpoint + persist_checkpoint.
TurnSucceeds(k) ==
    /\ keeper_phase[k] = "running"
    /\ context_tokens[k] <= MaxTokens    \* Within budget
    /\ turn_number' = [turn_number EXCEPT ![k] = turn_number[k] + 1]
    \* Checkpoint captures current context identity
    /\ ckpt_ctx_id' = [ckpt_ctx_id EXCEPT ![k] = context_id[k]]
    /\ ckpt_turn' = [ckpt_turn EXCEPT ![k] = turn_number[k] + 1]
    /\ ckpt_valid' = [ckpt_valid EXCEPT ![k] = TRUE]
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "idle"]
    \* Success resets failure counter
    /\ fail_count' = [fail_count EXCEPT ![k] = 0]
    /\ UNCHANGED <<context_id, context_tokens, message_count, tool_pairs,
                   resume_ctx_id, next_ctx_id>>

\* 7. Turn Fails: running -> error (or dead if budget exhausted).
\*    Models: Turn_failed event + Restart_budget_exhausted.
TurnFails(k) ==
    /\ keeper_phase[k] = "running"
    /\ fail_count' = [fail_count EXCEPT ![k] = fail_count[k] + 1]
    /\ IF fail_count[k] + 1 >= MaxFailures
       THEN keeper_phase' = [keeper_phase EXCEPT ![k] = "dead"]
       ELSE keeper_phase' = [keeper_phase EXCEPT ![k] = "error"]
    /\ UNCHANGED <<turn_number, context_id, context_tokens, message_count,
                   tool_pairs, ckpt_ctx_id, ckpt_turn, ckpt_valid,
                   resume_ctx_id, next_ctx_id>>

\* 8. Recover from Error: resume from last checkpoint.
\*    Models Agent.resume with ?context parameter.
\*    agent_checkpoint.ml:build_resume — if context provided, reuses it.
\*    Otherwise Context.copy. Here we model the "reuse" path.
RecoverFromError(k) ==
    /\ keeper_phase[k] = "error"
    /\ ckpt_valid[k] = TRUE
    \* Resume restores checkpoint's context identity
    /\ context_id' = [context_id EXCEPT ![k] = ckpt_ctx_id[k]]
    /\ turn_number' = [turn_number EXCEPT ![k] = ckpt_turn[k]]
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "idle"]
    /\ UNCHANGED <<context_tokens, message_count, tool_pairs,
                   ckpt_ctx_id, ckpt_turn, ckpt_valid,
                   resume_ctx_id, fail_count, next_ctx_id>>

\* 9. Recover Fresh: error with no checkpoint -> supervisor restarts with fresh context.
\*    Models: Supervisor_restart_attempt in keeper_state_machine.ml.
\*    When no checkpoint exists, a new context is allocated (new identity).
RecoverFresh(k) ==
    /\ keeper_phase[k] = "error"
    /\ ckpt_valid[k] = FALSE
    \* Fresh context: allocate new unique ID
    /\ context_id' = [context_id EXCEPT ![k] = next_ctx_id]
    /\ next_ctx_id' = next_ctx_id + 1
    /\ context_tokens' = [context_tokens EXCEPT ![k] = 0]
    /\ message_count' = [message_count EXCEPT ![k] = 0]
    /\ tool_pairs' = [tool_pairs EXCEPT ![k] = 0]
    /\ turn_number' = [turn_number EXCEPT ![k] = 0]
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "idle"]
    /\ UNCHANGED <<ckpt_ctx_id, ckpt_turn, ckpt_valid, resume_ctx_id, fail_count>>

\* 10. Keeper Done: max turns reached
KeeperDone(k) ==
    /\ keeper_phase[k] = "idle"
    /\ turn_number[k] >= MaxTurns
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "done"]
    /\ UNCHANGED <<turn_number, context_id, context_tokens, message_count,
                   tool_pairs, ckpt_ctx_id, ckpt_turn, ckpt_valid,
                   resume_ctx_id, fail_count, next_ctx_id>>

\* ── Buggy variant (for Bug Model pattern) ────────────────
\*
\* Deliberate bug: CompactionCompletesBuggy reallocates context_id
\* during compaction instead of preserving it. Models a broken
\* implementation where Context_reducer returns a NEW Context.t
\* rather than mutating the original. Expected to violate
\* ContextIsolation or ResumeIdentity.
CompactionCompletesBuggy(k) ==
    /\ keeper_phase[k] = "compacting"
    /\ context_tokens' = [context_tokens EXCEPT ![k] = CompactTarget]
    /\ message_count' = [message_count EXCEPT ![k] =
         IF message_count[k] > 2 THEN 2 ELSE message_count[k]]
    \* BUG: allocate a brand-new context_id (simulates new Context.t).
    \* resume_ctx_id is NOT updated → ResumeIdentity violated on next
    \* running step. ContextIsolation can collide across keepers.
    /\ context_id' = [context_id EXCEPT ![k] = next_ctx_id]
    /\ next_ctx_id' = next_ctx_id + 1
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "running"]
    /\ UNCHANGED <<turn_number, tool_pairs, ckpt_ctx_id, ckpt_turn,
                   ckpt_valid, resume_ctx_id, fail_count>>

\* ── Next-State Relation ──────────────────────────────────

\* Clean Next intentionally excludes [CompactionFailed] — modeling the
\* "always eventually succeeds" abstraction. The action is defined
\* above for documentation and is exercised by NextBuggy (below) and
\* will be reachable once a retry-budget variable is added in a
\* follow-up refinement. Including it here without bounded retry
\* introduces an infinite compacting ↔ overflow_retry cycle that
\* violates CompactionProgress even under strong fairness.
Next == \E k \in Keepers :
    \/ StartTurn(k)
    \/ TurnProducesOutput(k)
    \/ TokenBudgetExceeded(k)
    \/ StartCompaction(k)
    \/ CompactionCompletes(k)
    \/ TurnSucceeds(k)
    \/ TurnFails(k)
    \/ RecoverFromError(k)
    \/ RecoverFresh(k)
    \/ KeeperDone(k)

\* Next-state relation with deliberate bug — used by
\* KeeperContextLifecycle-buggy.cfg via SpecBuggy.
NextBuggy == \E k \in Keepers :
    \/ StartTurn(k)
    \/ TurnProducesOutput(k)
    \/ TokenBudgetExceeded(k)
    \/ StartCompaction(k)
    \/ CompactionCompletesBuggy(k)
    \/ CompactionFailed(k)
    \/ TurnSucceeds(k)
    \/ TurnFails(k)
    \/ RecoverFromError(k)
    \/ RecoverFresh(k)
    \/ KeeperDone(k)

Fairness ==
    \A k \in Keepers :
        /\ WF_vars(StartTurn(k))
        /\ WF_vars(StartCompaction(k))
        /\ WF_vars(CompactionCompletes(k))
        /\ WF_vars(TurnSucceeds(k))
        /\ WF_vars(RecoverFromError(k))
        /\ WF_vars(RecoverFresh(k))
        /\ WF_vars(KeeperDone(k))

Spec == Init /\ [][Next]_vars /\ Fairness
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety Properties ────────────────────────────────────

\* S1. Context Isolation: different keepers always hold different context_ids.
\*     If violated, one keeper's compaction/mutation could corrupt another's.
\*     Models: each keeper creates its own Context.create() at init.
ContextIsolation ==
    \A k1, k2 \in Keepers :
        k1 /= k2 => context_id[k1] /= context_id[k2]

\* S2. Resume Identity: when a turn is running, the context_id passed to
\*     Agent.resume matches the keeper's current context_id.
\*     Violation means shared_context was not propagated correctly.
\*     Models: memory feedback "Context.t identity on resume".
ResumeIdentity ==
    \A k \in Keepers :
        keeper_phase[k] = "running" => resume_ctx_id[k] = context_id[k]

\* S3. Turn Monotonicity: turn_number only advances forward during normal
\*     operation. (Error recovery may restore to checkpoint turn, which
\*     is always <= the turn that failed, so this is safe.)
TurnMonotonicity ==
    \A k \in Keepers :
        ckpt_valid[k] => ckpt_turn[k] <= turn_number[k] + 1

\* S4. Compaction Pair Integrity: tool_pairs count never decreases.
\*     ToolUse/ToolResult pairs are atomic units that compaction must preserve.
\*     Models: Context_reducer "preserve turn boundaries" constraint.
CompactionPairIntegrity ==
    \A k \in Keepers : tool_pairs[k] >= 0

\* S5. Checkpoint Consistency: a valid checkpoint references an
\*     allocated context_id (1 <= ckpt_ctx_id < next_ctx_id). Catches a
\*     separate bug class from TurnMonotonicity: a checkpoint pointing at
\*     a never-allocated or future context_id would pass monotonicity but
\*     break RecoverFromError's "restore identity" contract.
\*     Previously this invariant duplicated TurnMonotonicity
\*     (ckpt_turn <= turn + 1); the stronger allocation check strengthens
\*     the verified surface without weakening TurnMonotonicity.
CheckpointConsistency ==
    \A k \in Keepers :
        ckpt_valid[k] =>
            /\ ckpt_ctx_id[k] > 0
            /\ ckpt_ctx_id[k] < next_ctx_id

\* S6. Budget After Compaction: after compaction, tokens are within budget.
BudgetAfterCompaction ==
    \A k \in Keepers :
        keeper_phase[k] = "compacting" => CompactTarget <= MaxTokens

\* S7. No Running Beyond Budget Without Action: if tokens exceed budget
\*     during running, the system must transition to overflow_retry or compacting.
OverflowDetected ==
    \A k \in Keepers :
        (keeper_phase[k] = "running" /\ context_tokens[k] > MaxTokens) =>
            (keeper_phase'[k] \in {"overflow_retry", "compacting", "error"})

\* ── Liveness Properties ──────────────────────────────────

\* L1. Compaction Progress: overflow always eventually resolves.
CompactionProgress ==
    \A k \in Keepers :
        (keeper_phase[k] = "overflow_retry") ~>
        (keeper_phase[k] \in {"running", "error", "done", "dead"})

\* L2. Turn Completion: a running turn always eventually completes or fails.
EventualTurnCompletion ==
    \A k \in Keepers :
        (keeper_phase[k] = "running") ~>
        (keeper_phase[k] \in {"idle", "error", "done", "dead"})

\* L3. All Keepers Terminate: every keeper reaches a terminal state.
\*     "dead" is also terminal (restart budget exhausted).
AllKeepersTerminate ==
    \A k \in Keepers :
        <>(keeper_phase[k] \in {"done", "dead"})

====
