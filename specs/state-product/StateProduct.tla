---- MODULE StateProduct ----
\* Orthogonal State Machine Composition — TLA+ Formal Specification
\*
\* Models three independent FSMs composed as a product:
\*   1. Keeper (simplified: 5 key phases from 11-state FSM)
\*   2. Agent Turn (7 phases: pipeline stages)
\*   3. Tool Validation (7 phases: det/nondet correction)
\*
\* Verifies cross-dimension invariants that unit tests cannot:
\*   - Terminal keeper -> idle turn (safety)
\*   - Draining keeper -> no new turns (safety)
\*   - NonDet retry only during dispatch (boundary enforcement)
\*   - Compacting -> no LLM calls (resource safety)
\*   - Deadlock freedom for non-terminal product states
\*   - Liveness: validation eventually resolves
\*
\* Mirrors: lib/state_product.ml
\*
\* Two-config pattern (KeeperOASAdvanced precedent):
\*   StateProduct.cfg     — clean spec, all invariants must hold
\*   StateProduct-buggy.cfg — buggy spec, BoundaryViolated MUST be violated

EXTENDS Naturals

VARIABLES
    keeper,       \* Keeper lifecycle phase (simplified)
    turn,         \* Agent turn pipeline phase
    validation    \* Tool validation lifecycle phase

vars == <<keeper, turn, validation>>

\* ── Phase Sets ───────────────────────────────────────────

KeeperPhases == {"Offline", "Running", "Compacting", "Draining", "Stopped"}
TurnPhases == {"Idle", "Prompting", "Awaiting", "Parsing", "Dispatching", "Collecting", "Finalizing"}
ValidationPhases == {"Unchecked", "DetCorrecting", "DetValid", "DetInvalid", "NondetRetrying", "Valid", "Rejected"}

KeeperTerminal == {"Stopped"}
KeeperActive == KeeperPhases \ KeeperTerminal

\* ── Type Invariant ───────────────────────────────────────

TypeOK ==
    /\ keeper \in KeeperPhases
    /\ turn \in TurnPhases
    /\ validation \in ValidationPhases

\* ── Initial State ────────────────────────────────────────

Init ==
    /\ keeper = "Offline"
    /\ turn = "Idle"
    /\ validation = "Unchecked"

\* ── Keeper Events (simplified) ───────────────────────────

KeeperStart ==
    /\ keeper = "Offline"
    /\ keeper' = "Running"
    /\ UNCHANGED <<turn, validation>>

KeeperCompact ==
    /\ keeper = "Running"
    /\ turn \notin {"Prompting", "Awaiting"}  \* Guard: no compaction during LLM calls
    /\ keeper' = "Compacting"
    /\ UNCHANGED <<turn, validation>>

KeeperCompactDone ==
    /\ keeper = "Compacting"
    /\ keeper' = "Running"
    /\ UNCHANGED <<turn, validation>>

KeeperDrain ==
    /\ keeper = "Running"
    /\ turn /= "Prompting"       \* Guard: don't drain mid-prompt construction
    /\ keeper' = "Draining"
    /\ UNCHANGED <<turn, validation>>

KeeperStop ==
    /\ keeper = "Draining"
    /\ turn = "Idle"          \* can only stop when turn is idle
    /\ keeper' = "Stopped"
    /\ UNCHANGED <<turn, validation>>

\* ── Agent Turn Events ────────────────────────────────────

TurnStart ==
    /\ turn = "Idle"
    /\ keeper \in {"Running"}   \* no new turns during Compacting/Draining/Stopped
    /\ turn' = "Prompting"
    /\ validation' = "Unchecked"  \* reset validation for new turn
    /\ UNCHANGED <<keeper>>

TurnPrompt ==
    /\ turn = "Prompting"
    /\ turn' = "Awaiting"
    /\ UNCHANGED <<keeper, validation>>

TurnResponse ==
    /\ turn = "Awaiting"
    /\ turn' = "Parsing"
    /\ UNCHANGED <<keeper, validation>>

TurnParse ==
    /\ turn = "Parsing"
    /\ turn' = "Dispatching"
    /\ UNCHANGED <<keeper, validation>>

TurnDispatch ==
    /\ turn = "Dispatching"
    /\ validation \in {"Valid", "Rejected", "Unchecked"}  \* Guard: validation settled before collecting
    /\ turn' = "Collecting"
    /\ UNCHANGED <<keeper, validation>>

TurnCollect ==
    /\ turn = "Collecting"
    /\ turn' = "Finalizing"
    /\ UNCHANGED <<keeper, validation>>

TurnFinalize ==
    /\ turn = "Finalizing"
    /\ turn' = "Idle"
    /\ validation' = "Unchecked"  \* Reset for next turn
    /\ UNCHANGED <<keeper>>

TurnError ==
    /\ turn \in TurnPhases \ {"Idle"}
    /\ turn' = "Idle"
    /\ validation' = "Unchecked"  \* Error resets validation (cleanup)
    /\ UNCHANGED <<keeper>>

\* ── Tool Validation Events ───────────────────────────────

ValStart ==
    /\ validation = "Unchecked"
    /\ turn = "Dispatching"     \* validation only during dispatch
    /\ validation' = "DetCorrecting"
    /\ UNCHANGED <<keeper, turn>>

ValDetFixed ==
    /\ validation = "DetCorrecting"
    /\ validation' = "DetValid"
    /\ UNCHANGED <<keeper, turn>>

ValDetFailed ==
    /\ validation = "DetCorrecting"
    /\ validation' = "DetInvalid"
    /\ UNCHANGED <<keeper, turn>>

ValDetToValid ==
    /\ validation = "DetValid"
    /\ validation' = "Valid"
    /\ UNCHANGED <<keeper, turn>>

ValNondetAttempt ==
    /\ validation = "DetInvalid"
    /\ turn = "Dispatching"     \* NonDet only during dispatch
    /\ validation' = "NondetRetrying"
    /\ UNCHANGED <<keeper, turn>>

ValNondetFixed ==
    /\ validation = "NondetRetrying"
    /\ validation' = "Valid"
    /\ UNCHANGED <<keeper, turn>>

ValNondetExhausted ==
    /\ validation = "NondetRetrying"
    /\ validation' = "Rejected"
    /\ UNCHANGED <<keeper, turn>>

ValSkip ==
    /\ validation = "Unchecked"
    /\ validation' = "Valid"
    /\ UNCHANGED <<keeper, turn>>

\* ── Next State Relation ──────────────────────────────────

Next ==
    \/ KeeperStart \/ KeeperCompact \/ KeeperCompactDone
    \/ KeeperDrain \/ KeeperStop
    \/ TurnStart \/ TurnPrompt \/ TurnResponse \/ TurnParse
    \/ TurnDispatch \/ TurnCollect \/ TurnFinalize \/ TurnError
    \/ ValStart \/ ValDetFixed \/ ValDetFailed \/ ValDetToValid
    \/ ValNondetAttempt \/ ValNondetFixed \/ ValNondetExhausted
    \/ ValSkip

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants (cross-dimension) ──────────────────

\* I1: Keeper terminal -> turn must be idle
TerminalImpliesIdle ==
    keeper \in KeeperTerminal => turn = "Idle"

\* I2: Keeper draining -> turn must not START new turns (Prompting excluded)
\*     In-progress turns (Awaiting, Parsing, Dispatching, Collecting) are allowed
\*     because drain waits for the current turn to complete.
DrainingConstraint ==
    keeper = "Draining" => turn /= "Prompting"

\* I3: NonDet retrying -> turn must be dispatching
NondetRequiresDispatch ==
    validation = "NondetRetrying" => turn = "Dispatching"

\* I4: Keeper compacting -> turn not prompting or awaiting
CompactingNoNewLLM ==
    keeper = "Compacting" => turn \notin {"Prompting", "Awaiting"}

\* Combined safety invariant
SafetyInvariant ==
    /\ TypeOK
    /\ TerminalImpliesIdle
    /\ DrainingConstraint
    /\ NondetRequiresDispatch
    /\ CompactingNoNewLLM

\* ── Temporal Properties ──────────────────────────────────

\* P1: Terminal states are forever
StoppedIsForever == [](keeper = "Stopped" => [](keeper = "Stopped"))

\* P2: Validation eventually resolves (not stuck in DetCorrecting/NondetRetrying)
ValidationResolves ==
    (validation = "DetCorrecting") ~> (validation \in {"DetValid", "DetInvalid", "Valid", "Rejected", "Unchecked"})

NondetResolves ==
    (validation = "NondetRetrying") ~> (validation \in {"Valid", "Rejected", "Unchecked"})

\* P3: Draining eventually reaches Stopped (when turn finishes)
DrainingResolves ==
    (keeper = "Draining") ~> (keeper = "Stopped")

\* P4: Compacting eventually resolves
CompactingResolves ==
    (keeper = "Compacting") ~> (keeper = "Running")

\* ── Buggy Spec (for mutation testing) ────────────────────
\*
\* BugAction: skips the Det correction pipeline entirely —
\* jumps from Unchecked directly to NondetRetrying while turn is Idle.
\* This violates NondetRequiresDispatch (NonDet only during Dispatching).
\*
\* If BoundaryViolated is NOT violated, the invariant is too weak.

BugAction ==
    /\ validation = "Unchecked"
    /\ turn = "Idle"              \* BUG: NonDet retry without being in Dispatching
    /\ keeper = "Running"
    /\ validation' = "NondetRetrying"
    /\ UNCHANGED <<keeper, turn>>

NextBuggy == Next \/ BugAction
SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

\* The boundary invariant: NonDet retrying is only reachable from Dispatching.
\* Clean spec: holds. Buggy spec: MUST be violated.
BoundaryViolated == NondetRequiresDispatch

====
