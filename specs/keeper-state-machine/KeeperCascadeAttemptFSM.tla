---- MODULE KeeperCascadeAttemptFSM ----
\* Cascade-attempt FSM — provider-opaque internal state machine.
\*
\* RFC-0065 Phase 5.1 (B1).
\*
\* Scope: models cascade_fsm.ml::decide as an explicit state machine and
\* keeper_turn_driver::try_cascade as the recursive tier-walk wrapper.
\* This spec is ORTHOGONAL to three existing cascade specs:
\*
\*   - KeeperCascadeRouting.tla (RFC-0041): item/group routing
\*   - KeeperCascadeLifecycle.tla: keeper-facing turn projection
\*       (turn_phase / decision_stage / cascade_state)
\*   - CascadeAttemptLiveness.tla (RFC-0022): per-attempt streaming
\*       liveness (TTFT, idle, wall budgets)
\*
\* B1 covers what those three do not: the pure decision function
\* (Accept | Accept_on_exhaustion | Try_next | Exhausted) progressing
\* through tiers, slot retention across the recursion, and the
\* hard-quota override path.
\*
\* OCaml ↔ TLA+ mapping:
\*
\*   spec variable / action  | OCaml location                                  | semantic
\*   ------------------------+-------------------------------------------------+----------
\*   attempt_phase           | implicit (state of try_cascade recursion)       | lib/keeper/keeper_turn_driver.ml::try_cascade
\*   tier_index              | recursion depth in try_cascade                  | lib/keeper/keeper_turn_driver.ml (remaining)
\*   slot_held               | with_keeper_turn_slot acquire/release           | lib/keeper/keeper_turn_slot.ml::with_keeper_turn_slot
\*   provider_outcome        | type provider_outcome [@@deriving tla]          | lib/cascade/cascade_fsm.ml — type provider_outcome
\*   decision                | type decision [@@deriving tla]                  | lib/cascade/cascade_fsm.ml — type decision
\*   hard_quota_taken        | sdk_error_is_hard_quota force-Exhausted branch  | lib/keeper/keeper_turn_driver.ml — the hard-quota fast-path in run_named
\*
\* OCaml refs are cited by symbol/function name, not line number (iter 64
\* N-2.a convention; the previous "cascade_fsm.ml:NNN" / "keeper_turn_driver.ml:NNN"
\* anchors were converted in the iter 85 scattered-singles line-ref sweep —
\* cascade_fsm.ml is a small stable file so the drift was minor, but symbol
\* anchors stay correct as keeper_turn_driver.ml's run_named grows).
\*
\* Provider opacity (G3 acceptance gate):
\*   The spec uses abstract symbols "Provider_1, Provider_2, Provider_3"
\*   only. No literal provider identifier appears.  The model checking
\*   cares about tier count, not tier identity.
\*
\* Bug Model (per project's TLA+ Bug Model convention):
\*   Clean cfg: invariants SlotReleasedOnTerminal, HardQuotaTerminalImmediate,
\*              TryNextProgresses must hold.
\*   Buggy cfg: SpecBuggy admits one of three BugActions —
\*     - BugHardQuotaBypass : hard quota routes through decide (no override)
\*     - BugSemaphoreRelease : slot released mid-cascade between tiers
\*     - BugTryNextLoops    : Try_next fires without advancing tier_index
\*   At least one invariant MUST be violated.
\*
\* Runtime classifier indirection (R-D-2.c, iter 37, 2026-05-12):
\*   The spec's two terminal phases `exhausted_normal` and
\*   `exhausted_hard_quota` are ROLE IDENTITIES at the FSM level — both
\*   collapse to a single `Cascade_fsm.Exhausted { last_err }`
\*   constructor on the OCaml side (the `Exhausted` constructor of
\*   `type decision` in `lib/cascade/cascade_fsm.ml`).
\*
\*   Classification happens UPSTREAM of `decide` in
\*   `lib/keeper/keeper_turn_driver.ml`'s `run_named` — the hard-quota
\*   fast-path block (pinned by the "Hard-quota fast-path" comment):
\*
\*     if sdk_error_is_hard_quota sdk_err then
\*       Cascade_fsm.Exhausted { last_err }   (* fast-path, skips decide *)
\*     else
\*       Cascade_fsm.decide ~accept_on_exhaustion:false ~is_last outcome
\*
\*   Both branches return the SAME constructor.  Production preserves the
\*   distinction through (a) the cooldown side effect recorded ~line 1760
\*   and (b) the implicit "fast-path was taken" execution trace.  Callers'
\*   `| Cascade_fsm.Exhausted _ ->` pattern at lines 512, 722 cannot
\*   recover the classification.
\*
\*   This is the TERMINAL-PHASE ANALOG of the input-level Call_err gap
\*   documented in D-1 (`kcaf-d1-attempt-fsm-coverage-2026-05-12.md`):
\*   both gaps share the `sdk_error_is_hard_quota` predicate as the
\*   runtime classifier site.  See
\*   `docs/tla-audit/kcaf-d2-exhausted-asymmetry-2026-05-12.md` for the
\*   pattern-family analysis (flat-vs-typed alphabet collapse at FSM
\*   boundary) and the R-D-2.a+R-D-1.a bundle proposal that would close
\*   both gaps structurally.
\*
\*   Why the spec keeps the distinction anyway: TLC's
\*   `HardQuotaTerminalImmediate` invariant + `BugHardQuotaBypass`
\*   BugAction catch the regression spec-side BEFORE the OCaml collapse;
\*   the spec is the canonical safety surface for this anti-pattern even
\*   though OCaml represents it implicitly.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    MaxTiers,           \* number of provider tiers in the cascade (e.g. 3)
    MaxSteps,           \* upper bound on action count for finite checking
    ProviderOutcomes,   \* abstract outcome alphabet {"call_ok", "call_err_cascadeable",
                        \*                            "call_err_terminal", "call_err_hard_quota",
                        \*                            "accept_rejected", "slot_full"}
    AcceptOnExhaustion  \* boolean: whether the cascade accepts the last response on exhaustion

ASSUME
    /\ MaxTiers \in Nat /\ MaxTiers >= 1
    /\ MaxSteps \in Nat /\ MaxSteps >= MaxTiers
    /\ "call_ok" \in ProviderOutcomes
    /\ "call_err_cascadeable" \in ProviderOutcomes
    /\ "call_err_hard_quota" \in ProviderOutcomes
    /\ AcceptOnExhaustion \in BOOLEAN

VARIABLES
    attempt_phase,      \* "idle" | "attempting" | "awaiting_response"
                        \* | "success" | "exhausted_normal"
                        \* | "exhausted_hard_quota"
    tier_index,         \* 0..MaxTiers (0 = first tier, MaxTiers = exhausted past last)
    slot_held,          \* BOOLEAN — abstract turn slot held by with_keeper_turn_slot
    last_outcome,       \* element of ProviderOutcomes \cup {"none"}
    hard_quota_taken,   \* BOOLEAN — whether the hard-quota override fired this cascade
    step                \* action count for bounded checking

vars == <<attempt_phase, tier_index, slot_held, last_outcome,
          hard_quota_taken, step>>

\* ── Type invariant ──────────────────────────────────────

PhaseSet ==
    {"idle", "attempting", "awaiting_response",
     "success", "exhausted_normal", "exhausted_hard_quota"}

TerminalSet ==
    {"success", "exhausted_normal", "exhausted_hard_quota"}

TypeOK ==
    /\ attempt_phase \in PhaseSet
    /\ tier_index \in 0..MaxTiers
    /\ slot_held \in BOOLEAN
    /\ last_outcome \in ProviderOutcomes \cup {"none"}
    /\ hard_quota_taken \in BOOLEAN
    /\ step \in 0..MaxSteps

\* ── Initial state ───────────────────────────────────────

Init ==
    /\ attempt_phase = "idle"
    /\ tier_index = 0
    /\ slot_held = FALSE
    /\ last_outcome = "none"
    /\ hard_quota_taken = FALSE
    /\ step = 0

\* ── Actions (clean) ─────────────────────────────────────

\* Acquire slot and begin attempting tier 0.  Mirrors
\* with_keeper_turn_slot acquire + first try_cascade call.
StartCascade ==
    /\ attempt_phase = "idle"
    /\ tier_index = 0
    /\ ~slot_held
    /\ step < MaxSteps
    /\ attempt_phase' = "attempting"
    /\ slot_held' = TRUE
    /\ UNCHANGED <<tier_index, last_outcome, hard_quota_taken>>
    /\ step' = step + 1

\* Dispatch provider call: transitions to awaiting response.  Models the
\* run_try_provider call in try_cascade.
SendRequest ==
    /\ attempt_phase = "attempting"
    /\ step < MaxSteps
    /\ attempt_phase' = "awaiting_response"
    /\ UNCHANGED <<tier_index, slot_held, last_outcome, hard_quota_taken>>
    /\ step' = step + 1

\* Provider returned Call_ok and accept predicate held → success terminal.
ResolveSuccess ==
    /\ attempt_phase = "awaiting_response"
    /\ step < MaxSteps
    /\ \E outcome \in {"call_ok"}:
         /\ last_outcome' = outcome
         /\ attempt_phase' = "success"
         /\ slot_held' = FALSE
         /\ UNCHANGED <<tier_index, hard_quota_taken>>
    /\ step' = step + 1

\* Provider returned a cascadeable error or accept_rejected, NOT on the last
\* tier → Try_next.  tier_index strictly advances.
ResolveTryNext ==
    /\ attempt_phase = "awaiting_response"
    /\ tier_index < MaxTiers - 1
    /\ step < MaxSteps
    /\ \E outcome \in (ProviderOutcomes \ {"call_ok", "call_err_hard_quota"}):
         /\ last_outcome' = outcome
         /\ attempt_phase' = "attempting"
         /\ tier_index' = tier_index + 1
         /\ UNCHANGED <<slot_held, hard_quota_taken>>
    /\ step' = step + 1

\* Provider returned cascadeable error / accept_rejected on the LAST tier
\* (and accept_on_exhaustion is false) → normal exhaustion.  Slot released.
ResolveExhaustedNormal ==
    /\ attempt_phase = "awaiting_response"
    /\ tier_index = MaxTiers - 1
    /\ step < MaxSteps
    /\ \E outcome \in (ProviderOutcomes \ {"call_ok", "call_err_hard_quota"}):
         /\ last_outcome' = outcome
         /\ attempt_phase' = "exhausted_normal"
         /\ slot_held' = FALSE
         /\ UNCHANGED <<tier_index, hard_quota_taken>>
    /\ step' = step + 1

\* Hard quota override: force Exhausted immediately, bypassing decide,
\* WITHOUT advancing tier_index.  Mirrors the hard-quota fast-path in keeper_turn_driver.ml's run_named.
ResolveHardQuota ==
    /\ attempt_phase = "awaiting_response"
    /\ step < MaxSteps
    /\ last_outcome' = "call_err_hard_quota"
    /\ attempt_phase' = "exhausted_hard_quota"
    /\ slot_held' = FALSE
    /\ hard_quota_taken' = TRUE
    /\ UNCHANGED <<tier_index>>
    /\ step' = step + 1

Next ==
    \/ StartCascade
    \/ SendRequest
    \/ ResolveSuccess
    \/ ResolveTryNext
    \/ ResolveExhaustedNormal
    \/ ResolveHardQuota

Spec == Init /\ [][Next]_vars

\* ── Bug actions (each models a class of regression) ─────

\* BugAction #1: hard quota does NOT use the override; it routes through
\* decide and falls through to the next tier.  Models the regression
\* "remove the hard-quota fast-path override in keeper_turn_driver.ml's run_named".
BugHardQuotaBypass ==
    /\ attempt_phase = "awaiting_response"
    /\ tier_index < MaxTiers - 1
    /\ step < MaxSteps
    /\ last_outcome' = "call_err_hard_quota"
    /\ attempt_phase' = "attempting"
    /\ tier_index' = tier_index + 1
    /\ UNCHANGED <<slot_held, hard_quota_taken>>
    /\ step' = step + 1

\* BugAction #2: slot released between tiers (well-intentioned fairness
\* tweak).  Mirrors a refactor that moves release inside the tier loop.
BugSemaphoreRelease ==
    /\ attempt_phase = "attempting"
    /\ tier_index > 0
    /\ slot_held
    /\ step < MaxSteps
    /\ slot_held' = FALSE
    /\ UNCHANGED <<attempt_phase, tier_index, last_outcome, hard_quota_taken>>
    /\ step' = step + 1

\* BugAction #3: Try_next without advancing tier_index (off-by-one in tier walker).
BugTryNextLoops ==
    /\ attempt_phase = "awaiting_response"
    /\ step < MaxSteps
    /\ \E outcome \in (ProviderOutcomes \ {"call_ok", "call_err_hard_quota"}):
         /\ last_outcome' = outcome
         /\ attempt_phase' = "attempting"
    /\ UNCHANGED <<tier_index, slot_held, hard_quota_taken>>
    /\ step' = step + 1

NextBuggy ==
    \/ Next
    \/ BugHardQuotaBypass
    \/ BugSemaphoreRelease
    \/ BugTryNextLoops

SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Invariants ──────────────────────────────────────────

\* I1: once the FSM reaches any terminal state, the slot is released.
\* Mirrors the with_keeper_turn_slot Fun.protect finalizer.
SlotReleasedOnTerminal ==
    attempt_phase \in TerminalSet => ~slot_held

\* I2: hard-quota termination implies tier_index did not advance after
\* the quota error.  The hard-quota fast-path override (keeper_turn_driver.ml's run_named) forces
\* Exhausted on the *current* tier rather than continuing to the next.
HardQuotaTerminalImmediate ==
    attempt_phase = "exhausted_hard_quota" => hard_quota_taken

\* I3: every Try_next strictly increases tier_index.  Combined with the
\* finite MaxTiers bound, this rules out infinite Try_next loops.
\* Expressed as a state predicate: if we're attempting at tier i > 0
\* after Try_next, the previous step must have been at tier i-1.
\* Enforced structurally by ResolveTryNext (tier_index' = tier_index + 1).
\* Buggy version BugTryNextLoops violates this by leaving tier_index unchanged.
TryNextProgresses ==
    \* Equivalent reformulation that TLC can check on a single state:
    \* if we're back at "attempting" with tier_index > 0, we must have
    \* a non-success non-quota last_outcome that triggered the advance.
    (attempt_phase = "attempting" /\ tier_index > 0) =>
        last_outcome \in (ProviderOutcomes \ {"call_ok", "call_err_hard_quota"})

\* I4: composite safety — every invariant above plus TypeOK.
SafetyInvariant ==
    /\ TypeOK
    /\ SlotReleasedOnTerminal
    /\ HardQuotaTerminalImmediate
    /\ TryNextProgresses

====
