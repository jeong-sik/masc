---- MODULE KeeperCoreTriad ----
\* Keeper Core Triad — State x Decision x Runtime Unified Specification
\*
\* Composes three independently-verified subsystems into a single model
\* to verify cross-cutting safety and liveness properties:
\*
\*   State Machine  (KeeperStateMachine.tla)   — keeper phase lifecycle
\*   Decision       (KeeperDecisionPipeline.tla) — guard/tool policy
\*   Runtime        (RuntimeExhaustion.tla)    — provider fallback
\*
\* Key properties verified:
\*   S1 NoTerminalRuntime:       terminal phase => no runtime active
\*   S2 FailingUsesRecovery:     Failing => local_recovery runtime only
\*   S3 CapabilityGateHolds:     active attempt => ceiling >= requested
\*   S4 SideEffectContainment:   committed side effect + error => partial
\*   S5 PhaseDecisionConsistency: active turn => runtime selected
\*
\* Bug model: BugSelectRuntime removes phase-aware routing, reproducing
\* the Groq max_tokens ceiling violation (masc#6686).
\*
\* Mirrors: lib/keeper/keeper_turn_driver_try_runtime.ml (SelectRuntime action)
\*          lib/runtime/runtime_inference.ml (CapabilityGate action)
\*          lib/keeper/keeper_unified_turn.ml (turn lifecycle)
\*
\* OCaml mapping:
\*   phase              <-> Keeper_state_machine.phase (13-phase OCaml type
\*                          projected to a 7-symbol triad alphabet; see the
\*                          canonical mapping in the TypeOK preamble below.
\*                          Zombie added iter 4 #14707 is terminal post-Dead
\*                          (outside the turn cycle) and collapses into the
\*                          7-phase projection's "Stable" symbol — same arm
\*                          as Offline / Paused / Stopped / Crashed /
\*                          Restarting / Dead.  See KeeperCompositeLifecycle
\*                          Comment A for the canonical 13->7 mapping
\*                          (referred to as "Terminal" shorthand earlier in
\*                          some prose; the projection symbol is "Stable").)
\*   effective_runtime  <-> Keeper_turn_driver_try_runtime.run selected candidate
\*   provider_ceiling   <-> Oas_model_resolve.resolve_max_runtime_context
\*   requested_max_tokens <-> Runtime_inference.resolve_max_tokens
\*
\* (The canonical 13->7 phase mapping lives next to PhaseSet in this file
\*  (KeeperCompositeLifecycle Comment A is the SSOT).  Pre-Zombie this
\*  was "12->7"; iter 4 #14707 added Zombie which folds into the "Stable"
\*  symbol via the iter 51 #14865 mapping update.
\*  An earlier version of this preamble carried a separate "Phase
\*  simplification (12 -> 7)" mapping that classified HandingOff / Paused /
\*  Restarting differently from the canonical one.  Removed in #8970 to
\*  avoid the self-contradiction that TLC could not surface.)

EXTENDS Naturals

CONSTANTS
    MaxRetries,          \* Max cross-provider retries (e.g. 2)
    Provider1Ceiling,    \* max_tokens ceiling for provider 1
    Provider2Ceiling,    \* max_tokens ceiling for provider 2
    BaseRuntime,         \* keeper-configured base runtime name
    BaseRuntimeTokens,   \* max_tokens for the base runtime profile
    LocalRecoveryTokens, \* max_tokens for local_recovery profile
    LocalOnlyTokens      \* max_tokens for local_only profile

ASSUME /\ MaxRetries >= 0
       /\ BaseRuntime \notin {"local_recovery", "local_only", "none"}

NumProviders == 2
Providers == 1..NumProviders

\* Provider ceiling as a function from provider index to max_tokens.
ProviderCeiling(p) ==
    IF p = 1 THEN Provider1Ceiling ELSE Provider2Ceiling

\* ── Runtime profile definitions ─────────────────────────
\* Maps runtime name to its requested max_tokens.
\* Mirrors config/runtime.json profile -> max_tokens, with BaseRuntime
\* standing in for the keeper's configured profile (typically keeper_unified).

MaxTokensFor(runtime) ==
    CASE runtime = BaseRuntime      -> BaseRuntimeTokens
      [] runtime = "local_recovery" -> LocalRecoveryTokens
      [] runtime = "local_only"     -> LocalOnlyTokens
      [] OTHER                      -> 0

\* ── Variables ────────────────────────────────────────────

VARIABLES
    phase,               \* "Running" | "Failing" | "Overflowed" | "Compacting" | "HandingOff" | "Draining" | "Terminal"
    turn_status,         \* "idle" | "selecting" | "executing" | "retrying" | "done"
    effective_runtime,   \* BaseRuntime | "local_recovery" | "local_only" | "none"
    provider_idx,        \* 0..NumProviders (0 = exhausted or not started)
    requested_max_tokens,\* Nat (what the selected runtime demands)
    provider_result,     \* "pending" | "ok" | "error" | "capability_exceeded"
    has_side_effect,     \* BOOLEAN
    retry_count,         \* 0..MaxRetries
    turn_outcome         \* "none" | "success" | "error" | "partial_commit"

vars == <<phase, turn_status, effective_runtime, provider_idx,
          requested_max_tokens, provider_result, has_side_effect,
          retry_count, turn_outcome>>

\* ── Type Invariant ───────────────────────────────────────

\* Issue #8642/#8701 family: explicit OCaml ↔ TLA+ mapping. SSOT for
\* OCaml side is lib/keeper_registry/keeper_state_machine.ml (13 phases;
\* Zombie added iter 4 #14707).  This spec collapses the 12 non-Zombie
\* phases into a 7-symbol "core triad" alphabet
\* because the triad invariants only depend on running/failure/
\* compaction signals, not on the full keeper lifecycle. Mapping:
\*
\*   "Running"     ↔ Running
\*   "Failing"     ↔ Failing
\*   "Overflowed"  ↔ Overflowed
\*   "Compacting"  ↔ Compacting
\*   "HandingOff"  ↔ HandingOff
\*   "Draining"    ↔ Draining
\*   "Terminal"    ↔ Offline | Paused | Stopped | Crashed | Restarting | Dead | Zombie
\*
\* Zombie (added iter 4 #14707) is terminal-terminal: reached only
\* post-Dead when supervisor cleanup latches a never-cleared failure
\* (see ZombieIsForever / ZombieRequiresTerminalFailureLatched in
\* KeeperStateMachine.tla).  Collapsed into "Terminal" because the
\* core triad invariants do not distinguish Dead from Zombie — both
\* are terminal-with-no-progress for the running/failure/compaction
\* axes this spec tracks.
\*
\* Unmodeled here (covered in companion specs):
\*   none (all 13 OCaml phases are represented in the 7-symbol triad)
Phases == {"Running", "Failing", "Overflowed", "Compacting", "HandingOff", "Draining", "Terminal"}
TurnStatuses == {"idle", "selecting", "executing", "retrying", "done"}
Runtimes == {BaseRuntime, "local_recovery", "local_only", "none"}
ProviderResults == {"pending", "ok", "error", "capability_exceeded"}
TurnOutcomes == {"none", "success", "error", "partial_commit"}

TypeOK ==
    /\ phase \in Phases
    /\ turn_status \in TurnStatuses
    /\ effective_runtime \in Runtimes
    /\ provider_idx \in 0..NumProviders
    /\ requested_max_tokens \in Nat
    /\ provider_result \in ProviderResults
    /\ has_side_effect \in BOOLEAN
    /\ retry_count \in 0..MaxRetries
    /\ turn_outcome \in TurnOutcomes

\* ── Initial State ────────────────────────────────────────

Init ==
    /\ phase = "Running"
    /\ turn_status = "idle"
    /\ effective_runtime = "none"
    /\ provider_idx = 0
    /\ requested_max_tokens = 0
    /\ provider_result = "pending"
    /\ has_side_effect = FALSE
    /\ retry_count = 0
    /\ turn_outcome = "none"

\* ── Phase Transitions ────────────────────────────────────
\* Simplified from KeeperStateMachine.tla: only transitions relevant
\* to runtime routing behavior. Full phase verification is delegated
\* to the existing KeeperStateMachine spec.

\* Phase transitions only occur between turns (Eio cooperative scheduling:
\* heartbeat events are dispatched at loop boundaries, not during OAS calls).
\* Guard: turn_status must be "idle" or "done" for phase to change.

\* BecomeRunning is removed as a standalone action — it is driven by
\* TurnComplete feedback (turn success in Failing -> Running).
\* This mirrors OCaml: derive_phase returns Running when turn_healthy=true.

BecomeFailing ==
    /\ phase \in {"Running", "Compacting"}
    /\ turn_status \in {"idle", "done"}
    /\ phase' = "Failing"
    /\ UNCHANGED <<turn_status, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, has_side_effect,
                   retry_count, turn_outcome>>

BecomeCompacting ==
    /\ phase = "Running"
    /\ turn_status \in {"idle", "done"}
    /\ phase' = "Compacting"
    /\ UNCHANGED <<turn_status, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, has_side_effect,
                   retry_count, turn_outcome>>

BecomeHandingOff ==
    /\ phase = "Running"
    /\ turn_status \in {"idle", "done"}
    /\ phase' = "HandingOff"
    /\ UNCHANGED <<turn_status, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, has_side_effect,
                   retry_count, turn_outcome>>

BecomeDraining ==
    /\ phase \in {"Running", "Failing", "Compacting", "HandingOff"}
    /\ turn_status \in {"idle", "done"}
    /\ phase' = "Draining"
    /\ UNCHANGED <<turn_status, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, has_side_effect,
                   retry_count, turn_outcome>>

BecomeTerminal ==
    /\ phase \in {"Draining", "Failing"}
    /\ turn_status \in {"idle", "done"}
    /\ phase' = "Terminal"
    /\ effective_runtime' = "none"
    /\ UNCHANGED <<turn_status, provider_idx, requested_max_tokens,
                   provider_result, has_side_effect, retry_count,
                   turn_outcome>>

\* Context overflow detection: Running -> Overflowed.
\* Mirrors Context_overflow_detected event in keeper_state_machine.ml.
\* Guard: turn must be idle/done; mid-attempt overflow is left to the
\* in-flight runtime (it will fail naturally via ProviderError path).
BecomeOverflowed ==
    /\ phase = "Running"
    /\ turn_status \in {"idle", "done"}
    /\ phase' = "Overflowed"
    /\ UNCHANGED <<turn_status, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, has_side_effect,
                   retry_count, turn_outcome>>

\* Auto-compaction: Overflowed -> Compacting (Start_compaction entry action).
OverflowedBecomeCompacting ==
    /\ phase = "Overflowed"
    /\ turn_status \in {"idle", "done"}
    /\ phase' = "Compacting"
    /\ UNCHANGED <<turn_status, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, has_side_effect,
                   retry_count, turn_outcome>>

\* ── Turn Lifecycle: Select Runtime ───────────────────────
\* Mirrors: Keeper_turn_driver_try_runtime.run candidate selection
\* Pure abstraction: phase -> effective runtime role.

SelectRuntime ==
    /\ turn_status = "idle"
    /\ phase \notin {"Terminal", "Overflowed"}
       \* Terminal blocks all turns; Overflowed waits for auto-compaction
       \* (can_execute_turn=false in keeper_state_machine.ml).
    /\ turn_status' = "selecting"
    /\ effective_runtime' =
        IF phase = "Failing"    THEN "local_recovery"
        ELSE IF phase \in {"Compacting", "HandingOff"} THEN "local_only"
        ELSE BaseRuntime
    /\ requested_max_tokens' = MaxTokensFor(effective_runtime')
    /\ provider_idx' = 1
    /\ provider_result' = "pending"
    /\ has_side_effect' = FALSE
    /\ turn_outcome' = "none"
    /\ retry_count' = 0
    /\ UNCHANGED phase

\* ── Turn Lifecycle: Capability Gate + Attempt Provider ───
\* Mirrors: Runtime_inference.clamp_max_tokens_to_ceiling
\* If ceiling < requested, the request is clamped (not rejected).
\* The invariant S3 verifies that after clamping, the gate holds.

AttemptProvider ==
    /\ turn_status = "selecting"
    /\ provider_idx \in Providers
    /\ provider_result = "pending"
    \* Capability gate: clamp requested to ceiling
    /\ LET ceiling == ProviderCeiling(provider_idx)
           effective_tokens == IF requested_max_tokens > ceiling
                               THEN ceiling
                               ELSE requested_max_tokens
       IN
       /\ requested_max_tokens' = effective_tokens
       /\ turn_status' = "executing"
    /\ UNCHANGED <<phase, effective_runtime, provider_idx,
                   provider_result, has_side_effect, retry_count,
                   turn_outcome>>

\* ── Turn Lifecycle: Provider Outcomes ────────────────────

ProviderSuccess ==
    /\ turn_status = "executing"
    /\ provider_result' = "ok"
    /\ turn_outcome' = "success"
    /\ turn_status' = "done"
    /\ UNCHANGED <<phase, effective_runtime, provider_idx,
                   requested_max_tokens, has_side_effect, retry_count>>

ProviderError ==
    /\ turn_status = "executing"
    /\ ~has_side_effect     \* No committed side effect yet
    /\ provider_result' = "error"
    \* Try next provider if available
    /\ IF provider_idx < NumProviders
       THEN /\ provider_idx' = provider_idx + 1
            /\ turn_status' = "selecting"
            /\ provider_result' = "pending"
            /\ UNCHANGED <<turn_outcome, retry_count>>
       \* All providers exhausted, try cross-provider retry
       ELSE IF retry_count < MaxRetries
            THEN /\ retry_count' = retry_count + 1
                 /\ provider_idx' = 1
                 /\ turn_status' = "retrying"
                 /\ provider_result' = "pending"
                 /\ UNCHANGED turn_outcome
            ELSE /\ turn_outcome' = "error"
                 /\ turn_status' = "done"
                 /\ UNCHANGED <<provider_idx, retry_count>>
    /\ UNCHANGED <<phase, effective_runtime, requested_max_tokens,
                   has_side_effect>>

\* Side effect committed during execution (mutating tool ran)
SideEffectCommit ==
    /\ turn_status = "executing"
    /\ ~has_side_effect
    /\ has_side_effect' = TRUE
    /\ UNCHANGED <<phase, turn_status, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, retry_count,
                   turn_outcome>>

\* Error AFTER side effect committed -> partial_commit (retry blocked)
ProviderErrorAfterSideEffect ==
    /\ turn_status = "executing"
    /\ has_side_effect = TRUE
    /\ provider_result' = "error"
    /\ turn_outcome' = "partial_commit"
    /\ turn_status' = "done"
    /\ UNCHANGED <<phase, effective_runtime, provider_idx,
                   requested_max_tokens, has_side_effect, retry_count>>

\* Transient retry: re-enter runtime from provider 1
TransientRetry ==
    /\ turn_status = "retrying"
    /\ turn_status' = "selecting"
    /\ provider_result' = "pending"
    /\ UNCHANGED <<phase, effective_runtime, provider_idx,
                   requested_max_tokens, has_side_effect, retry_count,
                   turn_outcome>>

\* Turn completion: reset for next cycle + phase feedback.
\* Mirrors OCaml: TurnSucceeded -> turn_healthy=true -> derive_phase -> Running
\*                TurnFailed -> turn_healthy=false -> derive_phase -> Failing
TurnComplete ==
    /\ turn_status = "done"
    /\ turn_status' = "idle"
    /\ effective_runtime' = "none"
    /\ provider_idx' = 0
    /\ requested_max_tokens' = 0
    /\ provider_result' = "pending"
    /\ has_side_effect' = FALSE
    /\ retry_count' = 0
    \* Phase feedback: turn outcome drives phase transitions (derive_phase)
    /\ phase' =
        IF turn_outcome = "success" /\ phase = "Failing"
        THEN "Running"             \* Recovery: successful turn clears failure
        ELSE IF turn_outcome \in {"error", "partial_commit"} /\ phase = "Running"
        THEN "Failing"             \* Degradation: failed turn triggers failure
        ELSE phase                 \* No change for other combinations
    /\ UNCHANGED turn_outcome

\* ── Next-State Relation ──────────────────────────────────

Next ==
    \* Phase transitions (external events; BecomeRunning via TurnComplete)
    \/ BecomeFailing
    \/ BecomeCompacting
    \/ BecomeHandingOff
    \/ BecomeOverflowed
    \/ OverflowedBecomeCompacting
    \/ BecomeDraining
    \/ BecomeTerminal
    \* Turn lifecycle
    \/ SelectRuntime
    \/ AttemptProvider
    \/ ProviderSuccess
    \/ ProviderError
    \/ SideEffectCommit
    \/ ProviderErrorAfterSideEffect
    \/ TransientRetry
    \/ TurnComplete

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ────────────────────────────────────
\*
\* RUNTIME NAME ABSTRACTION (S1/S2/S3-buffer)
\* ----------------------------------------
\* The string literals "none", "local_recovery", and "local_only" used below
\* are SPEC-LEVEL CANONICAL ROLE NAMES, not literal OCaml return values.
\*
\* On the OCaml side, runtime ids are already resolved before
\* `Keeper_turn_driver_try_runtime.run` walks the candidate list.  The
\* literal strings below are therefore canonical *role identifiers* for
\* the spec, not production return values:
\*   - "none"           ↔ "no runtime is active for this turn"
\*   - "local_recovery" ↔ recovery runtime role
\*   - "local_only"     ↔ buffer-operation runtime role
\* TLC still compares strings; the semantic claim is role identity.
\* See `docs/tla-audit/kct-c3-terminal-runtime-contract-gap-2026-05-12.md`
\* and `docs/tla-audit/kct-s2s3-failing-buffer-runtime-alignment-2026-05-12.md`
\* (the latter lands via PR #14787) for the production indirection
\* analysis.

\* S1: Terminal phase never has an active runtime.
\* OCaml note: runtime attempts are upstream-gated for terminal phases, so
\* the spec-level empty role has no literal production counterpart.
NoTerminalRuntime ==
    phase = "Terminal" => effective_runtime = "none"

\* S2: Runtime selection in Failing phase must yield the Phase_recovery role.
\* Note: if a keeper transitions to Failing MID-TURN, the already-selected
\* runtime remains — runtime is chosen at turn start, not re-evaluated.
\* This invariant checks the selection action, not the runtime state.
\* OCaml: failing-turn recovery uses the resolved recovery runtime id.
FailingUsesRecovery ==
    (phase = "Failing" /\ turn_status = "selecting"
     /\ effective_runtime /= "none") =>
        effective_runtime = "local_recovery"

\* S3 (buffer): Runtime selection in buffer-operation phases must yield
\* the buffer-operation role.
BufferOpsUseLocalOnly ==
    (phase \in {"Compacting", "HandingOff"} /\ turn_status = "selecting"
     /\ effective_runtime /= "none") =>
        effective_runtime = "local_only"

\* S3: Active provider attempt respects ceiling
\* After clamping, requested_max_tokens <= provider ceiling
CapabilityGateHolds ==
    turn_status = "executing" =>
        requested_max_tokens <= ProviderCeiling(provider_idx)

\* S4: Side effect + error -> partial_commit (retry blocked)
SideEffectContainment ==
    (has_side_effect /\ turn_outcome \in {"error"}) => FALSE
    \* i.e., if side_effect is TRUE, outcome is never plain "error"
    \* it must be "partial_commit" instead

\* S5: Active turn has a runtime selected.
\*
\* Runtime-name abstraction: `"none"` here is the SPEC-LEVEL EMPTY-ROLE
\* MARKER — it asserts "no runtime is selected", not a literal string
\* match against an OCaml return value.  The OCaml side has no literal
\* "none"; the empty-role assertion is preserved structurally by the
\* caller graph upstream gating runtime attempts for non-active
\* turn_status values.
\*
\* The invariant therefore captures a structural property: candidate
\* selection in `lib/keeper/keeper_turn_driver_try_runtime.ml` uses a
\* non-empty runtime id for all phases that can co-occur with
\* turn_status in {selecting, executing, retrying}, namely
\* {Running, Failing, Compacting, HandingOff}.
PhaseDecisionConsistency ==
    turn_status \in {"selecting", "executing", "retrying"} =>
        effective_runtime /= "none"

SafetyInvariant ==
    /\ TypeOK
    /\ NoTerminalRuntime
    /\ FailingUsesRecovery
    /\ BufferOpsUseLocalOnly
    /\ CapabilityGateHolds
    /\ SideEffectContainment
    /\ PhaseDecisionConsistency

\* ── Liveness Properties ──────────────────────────────────

\* L1: Running keeper with at least one capable provider eventually succeeds
\* (or transitions to another phase)
RunningEventuallyCompletes ==
    (phase = "Running" /\ turn_status /= "idle") ~>
        (turn_status = "done" \/ phase /= "Running")

\* L2: Failing phase eventually resolves — DELEGATED to KeeperStateMachine.tla.
\* This property may require external operator approval/recovery clearance,
\* which is outside runtime routing scope. The counterexample: partial_commit
\* in Failing creates a cycle only breakable by external action + next success.
\* Retained as definition for documentation; removed from cfg PROPERTIES.
FailingResolves ==
    phase = "Failing" ~> phase /= "Failing"

\* L3: No deadlock on capability exceeded
CapabilityNeverDeadlocks ==
    turn_status = "executing" ~> turn_status \in {"done", "idle", "selecting", "retrying"}

\* ── Bug Model ────────────────────────────────────────────
\* Reproduces masc#6686: phase-unaware runtime selection
\* sends 65536 max_tokens to a provider with 40960 ceiling.

BugSelectRuntime ==
    /\ turn_status = "idle"
    /\ phase \notin {"Terminal", "Overflowed"}
    /\ turn_status' = "selecting"
    \* BUG: always use the configured base runtime regardless of phase
    /\ effective_runtime' = BaseRuntime
    /\ requested_max_tokens' = BaseRuntimeTokens
    /\ provider_idx' = 1
    /\ provider_result' = "pending"
    /\ has_side_effect' = FALSE
    /\ turn_outcome' = "none"
    /\ retry_count' = 0
    /\ UNCHANGED phase

\* Bug model: skip capability gate clamping
BugAttemptProvider ==
    /\ turn_status = "selecting"
    /\ provider_idx \in Providers
    /\ provider_result = "pending"
    \* BUG: no clamping, send raw requested_max_tokens
    /\ turn_status' = "executing"
    /\ UNCHANGED <<phase, effective_runtime, provider_idx,
                   requested_max_tokens, provider_result, has_side_effect,
                   retry_count, turn_outcome>>

NextBuggy ==
    \/ BecomeFailing
    \/ BecomeCompacting
    \/ BecomeDraining
    \/ BecomeTerminal
    \/ BugSelectRuntime         \* replaces SelectRuntime
    \/ BugAttemptProvider        \* replaces AttemptProvider
    \/ ProviderSuccess
    \/ ProviderError
    \/ SideEffectCommit
    \/ ProviderErrorAfterSideEffect
    \/ TransientRetry
    \/ TurnComplete

SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

====
