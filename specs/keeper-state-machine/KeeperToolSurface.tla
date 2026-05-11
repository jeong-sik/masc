---- MODULE KeeperToolSurface ----
\* Tool surface pipeline — provider-opaque set transformations.
\*
\* RFC-0065 Phase 5.2 (B2).
\*
\* Scope: models the 11-step compute_tool_surface pipeline as ordered
\* set transformations over an abstract universe of tool atoms.
\* This spec is ORTHOGONAL to the four existing keeper specs:
\*
\*   - KeeperStateMachine.tla         (keeper lifecycle)
\*   - KeeperCascadeRouting.tla       (cascade item/group routing)
\*   - KeeperCascadeAttemptFSM.tla    (RFC-0065 B1 — cascade attempt FSM)
\*   - KeeperRolloverDecision.tla     (rollover gate, RFC-0065 Phase 4)
\*
\* B2 covers what those do not: the surface-construction pipeline
\* invariants (validate gate, last-turn safety monotonicity, fallback
\* floor conditioning, max-tools cap with required preservation).
\*
\* OCaml ↔ TLA+ mapping:
\*
\*   spec variable           | OCaml location                                            | semantic
\*   ------------------------+-----------------------------------------------------------+---------
\*   pre_floor               | merged after overlay compose+validate                     | lib/keeper/keeper_run_tools.ml:830-836
\*   floor_fired             | tool_surface_fallback_used = true                         | lib/keeper/keeper_run_tools.ml:844-850
\*   after_floor             | all_allowed post fallback floor                           | lib/keeper/keeper_run_tools.ml:850
\*   after_last_turn_safe    | Intersect_with safe_last_turn_tools (when is_last_turn)   | lib/keeper/keeper_run_tools.ml:866-873
\*   after_passive           | contract_enforcement_filter output                        | lib/keeper/keeper_run_tools.ml:882-888
\*   emitted                 | all_allowed (final return)                                | lib/keeper/keeper_run_tools.ml:909-944
\*   required                | required_tool_names (post satisfaction)                   | lib/keeper/keeper_run_tools.ml:794-797
\*
\* Provider opacity (G3 acceptance gate):
\*   The Tools universe is an abstract set of atoms ("t1", "t2", …) only.
\*   AlwaysAffordanceless is an opaque subset modeling tools that the
\*   validate_allow_list pipeline excludes from the affordanced surface
\*   (mirrors the OCaml missing_required_tool_names carve-out).  No
\*   literal tool name (e.g. "read_file", "bash") appears in this spec.
\*
\* Bug Model (per project's TLA+ Bug Model convention):
\*   Clean cfg: invariants RequiredSubsetEmitted, LastTurnSafeMonotone,
\*              FallbackFloorOnlyWhenEmpty, MaxToolsCap must hold.
\*   Buggy cfg: SpecBuggy admits one of four BugActions —
\*     - BugRequiredEscapesValidate : validate_allow_list bypass
\*     - BugLastTurnSafeAdds        : last-turn-safe filter as union
\*     - BugFallbackFloorAlwaysOn   : floor fires unconditionally
\*     - BugMaxToolsDropsRequired   : truncation drops required tools
\*   At least one safety invariant MUST be violated under SpecBuggy.

EXTENDS Naturals, FiniteSets

CONSTANTS
    Tools,                  \* abstract universe of tool atoms (e.g. {"t1", "t2", "t3"})
    AlwaysAffordanceless,   \* subset of Tools whose presence in Required
                            \* is allowed to bypass RequiredSubsetEmitted
                            \* (mirrors the OCaml missing_required carve-out)
    MaxToolsPerTurn,        \* per-turn truncation cap (e.g. 2)
    MaxSteps                \* upper bound on action count for bounded checking

ASSUME
    /\ MaxToolsPerTurn \in Nat /\ MaxToolsPerTurn >= 1
    /\ MaxSteps \in Nat /\ MaxSteps >= 1
    /\ AlwaysAffordanceless \subseteq Tools

VARIABLES
    phase,                  \* "idle" | "computed"
    required,               \* SUBSET Tools — required for the turn
    pre_floor,              \* SUBSET Tools — output of overlay-compose+validate
    floor_fired,            \* BOOLEAN — whether the fallback floor injected
    after_floor,            \* SUBSET Tools — after the floor stage
    after_last_turn_safe,   \* SUBSET Tools — after the last-turn-safe intersect
    is_last_turn,           \* BOOLEAN — whether the last-turn-safe stage runs
    after_passive,          \* SUBSET Tools — after contract_enforcement_filter
    emitted,                \* SUBSET Tools — final pipeline output (after truncation)
    step                    \* action count

vars == <<phase, required, pre_floor, floor_fired, after_floor,
          after_last_turn_safe, is_last_turn, after_passive, emitted,
          step>>

\* ── Type invariant ──────────────────────────────────────

PhaseSet == {"idle", "computed"}

\* Observable label catalogs (cross-referenced by the OCaml ↔ TLA+
\* correspondence harness).  These do not participate in Actions or
\* SafetyInvariant — they pin the downstream-visible classification
\* strings emitted at keeper_run_tools.ml:949-973.
SurfaceClassSet == {"none", "public_only", "mixed"}
RequirementSet == {"no_tools", "required", "optional"}

TypeOK ==
    /\ phase \in PhaseSet
    /\ required \subseteq Tools
    /\ pre_floor \subseteq Tools
    /\ floor_fired \in BOOLEAN
    /\ after_floor \subseteq Tools
    /\ after_last_turn_safe \subseteq Tools
    /\ is_last_turn \in BOOLEAN
    /\ after_passive \subseteq Tools
    /\ emitted \subseteq Tools
    /\ step \in 0..MaxSteps

\* ── Initial state ───────────────────────────────────────

Init ==
    /\ phase = "idle"
    /\ required = {}
    /\ pre_floor = {}
    /\ floor_fired = FALSE
    /\ after_floor = {}
    /\ after_last_turn_safe = {}
    /\ is_last_turn = FALSE
    /\ after_passive = {}
    /\ emitted = {}
    /\ step = 0

\* ── Helper: truncation preserving required tools ────────

\* The OCaml truncation (keeper_run_tools.ml:909-944) splits all_allowed
\* into "essential" (required + always-include) and "non-essential",
\* keeps essentials, then takes the first (cap - |essential|) of the
\* non-essentials.  Abstracted here as: any subset T of S with size
\* ≤ MaxToolsPerTurn that contains the required-and-affordanced subset.
TruncatePreservingRequired(S, R) ==
    {T \in SUBSET S :
        /\ (R \cap S) \subseteq T
        /\ Cardinality(T) <= MaxToolsPerTurn}

\* ── Actions (clean) ─────────────────────────────────────

\* ComputePipeline: non-deterministically pick the turn inputs
\* (required, pre_floor, is_last_turn) and the stage-specific knobs
\* (floor injection, last-turn-safe whitelist, passive drop set),
\* then run the clean pipeline atomically.  Mirrors compute_tool_surface:
\*
\*   pre_floor →
\*     floor (fires only when pre_floor is empty) →
\*     last_turn_safe (intersect, only when is_last_turn) →
\*     passive (subset filter — removes elements only) →
\*     truncation (preserves required, ≤ MaxToolsPerTurn)
\*
ComputePipeline ==
    /\ phase = "idle"
    /\ step < MaxSteps
    /\ \E r \in SUBSET Tools,
         p \in SUBSET Tools,
         ilt \in BOOLEAN,
         floor_inj \in SUBSET Tools,
         lts_safe \in SUBSET Tools,
         passive_drop \in SUBSET Tools,
         post_trunc \in SUBSET Tools:
       LET
         \* Stage F: fallback floor — fires only when upstream is empty.
         floored == IF p = {} THEN floor_inj ELSE p
         did_floor == (p = {}) /\ (floor_inj /= {})
         \* Stage L: last-turn-safe intersect (only when is_last_turn).
         lts == IF ilt THEN floored \cap lts_safe ELSE floored
         \* Stage P: passive filter — removes elements only.
         after_pass == lts \ passive_drop
         \* Stage T: truncation — preserves (required ∩ after_pass).
         is_trunc == post_trunc \in TruncatePreservingRequired(after_pass, r)
         \* Required-affordanced subset (what the contract must preserve).
         r_aff == r \ AlwaysAffordanceless
       IN
       \* Pipeline contract — clean stages must preserve required-affordanced
       \* tools end-to-end.  Each constraint mirrors an OCaml guarantee:
       \*   - validate gate at keeper_run_tools.ml:805-806/830-836 ensures
       \*     required (post validate_allow_list) is in pre_floor.
       \*   - contract_enforcement_filter at keeper_run_tools.ml:882-888
       \*     does not drop required-affordanced tools.
       \*   - safe_last_turn_tools at keeper_run_tools.ml:856-865 includes
       \*     required-affordanced tools when is_last_turn fires.
       /\ r_aff \subseteq p
       /\ passive_drop \cap r_aff = {}
       /\ (~ilt) \/ (r_aff \subseteq lts_safe)
       /\ is_trunc
       /\ required' = r
       /\ pre_floor' = p
       /\ floor_fired' = did_floor
       /\ after_floor' = floored
       /\ is_last_turn' = ilt
       /\ after_last_turn_safe' = lts
       /\ after_passive' = after_pass
       /\ emitted' = post_trunc
       /\ phase' = "computed"
       /\ step' = step + 1

\* Reset: return to idle so multiple turns can run within MaxSteps.
Reset ==
    /\ phase = "computed"
    /\ step < MaxSteps
    /\ phase' = "idle"
    /\ required' = {}
    /\ pre_floor' = {}
    /\ floor_fired' = FALSE
    /\ after_floor' = {}
    /\ after_last_turn_safe' = {}
    /\ is_last_turn' = FALSE
    /\ after_passive' = {}
    /\ emitted' = {}
    /\ step' = step + 1

Next ==
    \/ ComputePipeline
    \/ Reset

Spec == Init /\ [][Next]_vars

\* ── Bug actions (each models a class of regression) ─────

\* BugAction #1: validate_allow_list bypass — required tools that are
\* outside the affordanced universe leak straight to emitted without
\* the validate stage trimming them.  Mirrors a refactor that removes
\* validate_allow_list from the overlay compose path.
BugRequiredEscapesValidate ==
    /\ phase = "idle"
    /\ step < MaxSteps
    /\ \E r \in SUBSET Tools,
         p \in SUBSET Tools,
         ilt \in BOOLEAN,
         escaped \in SUBSET Tools:
       /\ r /= {}
       /\ (r \cap AlwaysAffordanceless) = {}
       /\ ~(r \subseteq escaped)
       /\ required' = r
       /\ pre_floor' = p
       /\ floor_fired' = FALSE
       /\ after_floor' = p
       /\ is_last_turn' = ilt
       /\ after_last_turn_safe' = p
       /\ after_passive' = p
       /\ emitted' = escaped
       /\ phase' = "computed"
       /\ step' = step + 1

\* BugAction #2: last-turn-safe is implemented as a *union* with the
\* safe whitelist instead of an *intersect*.  Drops the monotone
\* guarantee — re-introduces tools the policy excluded.
BugLastTurnSafeAdds ==
    /\ phase = "idle"
    /\ step < MaxSteps
    /\ \E r \in SUBSET Tools,
         p \in SUBSET Tools,
         lts_safe \in SUBSET Tools,
         passive_drop \in SUBSET Tools,
         post_trunc \in SUBSET Tools:
       LET
         floored == p
         lts == floored \cup lts_safe
         after_pass == lts \ passive_drop
         is_trunc == post_trunc \in TruncatePreservingRequired(after_pass, r)
       IN
       /\ is_trunc
       /\ \E t \in lts_safe: t \notin floored
       /\ required' = r
       /\ pre_floor' = p
       /\ floor_fired' = FALSE
       /\ after_floor' = floored
       /\ is_last_turn' = TRUE
       /\ after_last_turn_safe' = lts
       /\ after_passive' = after_pass
       /\ emitted' = post_trunc
       /\ phase' = "computed"
       /\ step' = step + 1

\* BugAction #3: fallback floor fires unconditionally — even when
\* upstream is non-empty.  Defense-in-depth turned into permissive
\* default; historically suspected as the "always show floor" pattern.
BugFallbackFloorAlwaysOn ==
    /\ phase = "idle"
    /\ step < MaxSteps
    /\ \E r \in SUBSET Tools,
         p \in SUBSET Tools,
         floor_inj \in SUBSET Tools,
         passive_drop \in SUBSET Tools,
         post_trunc \in SUBSET Tools:
       LET
         floored == p \cup floor_inj
         after_pass == floored \ passive_drop
         is_trunc == post_trunc \in TruncatePreservingRequired(after_pass, r)
       IN
       /\ is_trunc
       /\ p /= {}
       /\ floor_inj /= {}
       /\ required' = r
       /\ pre_floor' = p
       /\ floor_fired' = TRUE
       /\ after_floor' = floored
       /\ is_last_turn' = FALSE
       /\ after_last_turn_safe' = floored
       /\ after_passive' = after_pass
       /\ emitted' = post_trunc
       /\ phase' = "computed"
       /\ step' = step + 1

\* BugAction #4: truncation drops required tools.  Models a regression
\* where the essential/non-essential split is removed and truncation
\* simply takes the first MaxToolsPerTurn elements regardless of
\* required membership.
BugMaxToolsDropsRequired ==
    /\ phase = "idle"
    /\ step < MaxSteps
    /\ \E r \in SUBSET Tools,
         p \in SUBSET Tools,
         passive_drop \in SUBSET Tools,
         post_trunc \in SUBSET Tools:
       LET
         floored == p
         lts == floored
         after_pass == lts \ passive_drop
       IN
       /\ post_trunc \subseteq after_pass
       /\ Cardinality(post_trunc) <= MaxToolsPerTurn
       /\ (r \cap after_pass) /= {}
       /\ ~((r \cap after_pass) \subseteq post_trunc)
       /\ required' = r
       /\ pre_floor' = p
       /\ floor_fired' = FALSE
       /\ after_floor' = floored
       /\ is_last_turn' = FALSE
       /\ after_last_turn_safe' = lts
       /\ after_passive' = after_pass
       /\ emitted' = post_trunc
       /\ phase' = "computed"
       /\ step' = step + 1

NextBuggy ==
    \/ Next
    \/ BugRequiredEscapesValidate
    \/ BugLastTurnSafeAdds
    \/ BugFallbackFloorAlwaysOn
    \/ BugMaxToolsDropsRequired

SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Invariants ──────────────────────────────────────────

\* I1: required tools must be preserved through to emitted, unless the
\* affordance-less carve-out applies.  Mirrors the surface-mismatch
\* guard at keeper_run_tools.ml:998-1011 at the model-checking layer.
RequiredSubsetEmitted ==
    phase = "computed" =>
        \/ required \subseteq emitted
        \/ (required \cap AlwaysAffordanceless) /= {}

\* I2: last-turn-safe stage only *removes* tools — it is an intersect,
\* never a union.  Pinned by the implementation at
\* keeper_run_tools.ml:866-873 (Intersect_with).
LastTurnSafeMonotone ==
    phase = "computed" => after_last_turn_safe \subseteq after_floor

\* I3: fallback floor fires only when the upstream surface is empty.
\* Models the explicit conditional at keeper_run_tools.ml:844-850.
FallbackFloorOnlyWhenEmpty ==
    (phase = "computed" /\ floor_fired) => (pre_floor = {})

\* I4: truncation cap is honored AND required tools that survived
\* upstream are preserved.  Mirrors the essential/non-essential split
\* at keeper_run_tools.ml:909-944.
MaxToolsCap ==
    phase = "computed" =>
        /\ Cardinality(emitted) <= MaxToolsPerTurn
        /\ (required \cap after_passive) \subseteq emitted

\* I5: composite safety — every invariant above plus TypeOK.
SafetyInvariant ==
    /\ TypeOK
    /\ RequiredSubsetEmitted
    /\ LastTurnSafeMonotone
    /\ FallbackFloorOnlyWhenEmpty
    /\ MaxToolsCap

====
