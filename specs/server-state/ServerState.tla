---- MODULE ServerState ----
\* Server Lifecycle Orthogonal State Machine — TLA+ Formal Specification
\*
\* Models three independent FSMs composed as a product:
\*   1. Lifecycle  (Booting | Serving | Draining | Stopped)
\*   2. LazyQueue  (Complete | Pending)  — simplified boolean for spec
\*   3. Readiness  (NotReady | Ready)
\*
\* Product state count: 4 x 2 x 2 = 16 states
\*
\* Verifies cross-dimension invariants that flat-variant code cannot:
\*   - Ready implies not booting (safety)
\*   - Stopped implies not ready (safety)
\*   - Pending tasks block stop (safety)
\*   - Deadlock freedom for non-terminal product states
\*   - Liveness: draining eventually stops
\*
\* Mirrors: lib/server_state_product.ml
\*
\* Two-config pattern (clean model plus an explicit buggy model):
\*   ServerState.cfg      — clean spec, all invariants must hold
\*   ServerState-buggy.cfg — buggy spec, InvariantViolated MUST be violated

EXTENDS Naturals

VARIABLES
    lifecycle,    \* Server lifecycle phase
    lazy_pending, \* TRUE if lazy tasks pending
    readiness     \* Traffic readiness

vars == <<lifecycle, lazy_pending, readiness>>

\* ── Phase Sets ───────────────────────────────────────────

LifecyclePhases == {"Booting", "Serving", "Draining", "Stopped"}
ReadinessPhases == {"NotReady", "Ready"}

LifecycleTerminal == {"Stopped"}
LifecycleActive == LifecyclePhases \ LifecycleTerminal

\* ── Type Invariant ───────────────────────────────────────

TypeOK ==
    /\ lifecycle \in LifecyclePhases
    /\ lazy_pending \in BOOLEAN
    /\ readiness \in ReadinessPhases

\* ── Initial State ────────────────────────────────────────

Init ==
    /\ lifecycle = "Booting"
    /\ lazy_pending = FALSE
    /\ readiness = "NotReady"

\* ── Lifecycle Events ─────────────────────────────────────

LifecycleBootComplete ==
    /\ lifecycle = "Booting"
    /\ lifecycle' = "Serving"
    /\ UNCHANGED <<lazy_pending, readiness>>

LifecycleStartDraining ==
    /\ lifecycle = "Serving"
    /\ lifecycle' = "Draining"
    /\ UNCHANGED <<lazy_pending, readiness>>

LifecycleStop ==
    /\ lifecycle = "Draining"
    /\ lazy_pending = FALSE
    /\ readiness = "NotReady"
    /\ lifecycle' = "Stopped"
    /\ UNCHANGED <<lazy_pending, readiness>>

\* ── Lazy Task Events ─────────────────────────────────────

LazyTasksAppear ==
    /\ lazy_pending = FALSE
    /\ lifecycle # "Stopped"
    /\ lazy_pending' = TRUE
    /\ UNCHANGED <<lifecycle, readiness>>

LazyTasksComplete ==
    /\ lazy_pending = TRUE
    /\ lazy_pending' = FALSE
    /\ UNCHANGED <<lifecycle, readiness>>

\* ── Readiness Events ─────────────────────────────────────

ReadinessReady ==
    /\ readiness = "NotReady"
    /\ lifecycle \in {"Serving", "Draining"}
    /\ readiness' = "Ready"
    /\ UNCHANGED <<lifecycle, lazy_pending>>

ReadinessNotReady ==
    /\ readiness = "Ready"
    /\ lifecycle \in {"Serving", "Draining"}
    /\ readiness' = "NotReady"
    /\ UNCHANGED <<lifecycle, lazy_pending>>

\* ── Next State Relation ──────────────────────────────────

Next ==
    \/ LifecycleBootComplete
    \/ LifecycleStartDraining
    \/ LifecycleStop
    \/ LazyTasksAppear
    \/ LazyTasksComplete
    \/ ReadinessReady
    \/ ReadinessNotReady

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants (cross-dimension) ──────────────────

\* I1: Ready implies not booting
ReadyImpliesNotBooting ==
    readiness = "Ready" => lifecycle \in {"Serving", "Draining"}

\* I2: Stopped implies not ready
StoppedImpliesNotReady ==
    lifecycle = "Stopped" => readiness = "NotReady"

\* I3: Pending tasks block stop
PendingBlocksStop ==
    lazy_pending = TRUE => lifecycle # "Stopped"

\* Combined safety invariant
SafetyInvariant ==
    /\ TypeOK
    /\ ReadyImpliesNotBooting
    /\ StoppedImpliesNotReady
    /\ PendingBlocksStop

\* ── Temporal Properties ──────────────────────────────────

\* P1: Terminal states are forever
StoppedIsForever == [](lifecycle = "Stopped" => [](lifecycle = "Stopped"))

\* P2: Draining eventually reaches Stopped
DrainingResolves ==
    (lifecycle = "Draining") ~> (lifecycle = "Stopped")

\* ── Buggy Spec (for mutation testing) ────────────────────
\*
\* BugAction: sets readiness to Ready while still in Booting.
\* This violates ReadyImpliesNotBooting (I1).
\*
\* If InvariantViolated is NOT violated, the invariant is too weak.

BugAction ==
    /\ lifecycle = "Booting"
    /\ readiness = "NotReady"
    /\ readiness' = "Ready"
    /\ UNCHANGED <<lifecycle, lazy_pending>>

NextBuggy == Next \/ BugAction
SpecBuggy == Init /\ [][NextBuggy]_vars /\ WF_vars(NextBuggy)

\* The invariant that should be violated in the buggy spec
InvariantViolated == ReadyImpliesNotBooting

====
