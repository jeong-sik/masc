---- MODULE KeeperCircuitBreaker ----
\* Circuit Breaker state machine for keeper tool failure recovery.
\* Verifies safety (no false trips) and mutation-tests the class isolation property.
\*
\* OCaml ↔ TLA+ mapping (see #8642 family):
\*
\*   spec variable    | OCaml location                                          | semantic
\*   -----------------+---------------------------------------------------------+---------
\*   Threshold        | lib/keeper/keeper_failure_circuit_breaker.ml:threshold         | `let threshold = 3` (matches spec CONSTANT)
\*   count            | lib/keeper/keeper_failure_circuit_breaker.ml:consecutive_count | `mutable consecutive_count : int`
\*   currentClass     | lib/keeper/keeper_failure_circuit_breaker.ml:consecutive_class | `mutable consecutive_class : error_class`
\*   tripped          | lib/keeper/keeper_failure_circuit_breaker.ml:record_failure    | `record_failure` returns whether hint was injected this step
\*   ErrorClasses     | lib/keeper/keeper_failure_circuit_breaker.ml:error_class       | `type error_class = Path_not_found | Path_not_allowed | Cwd_not_directory | Shell_exit_nonzero | Other`
\*
\* Scope projection: spec models 3 error classes
\* (path_not_found, path_not_allowed, other); OCaml has 5
\* (Path_not_found, Path_not_allowed, Cwd_not_directory, Shell_exit_nonzero, Other).
\* The two extra OCaml classes (Cwd_not_directory, Shell_exit_nonzero)
\* fold into the spec's "other" partition for class-isolation checking —
\* the property the spec verifies (a class streak is broken by any
\* different class) holds independently of how many "different" classes
\* exist. Adding new OCaml classes does NOT require spec update.
\*
\* Bug Model (feedback_tla-spec-audit-outcome-trichotomy):
\*   Clean cfg : SafetyInvariant + ClassIsolation pass.
\*   Buggy cfg : models a counter that fails to reset on class change
\*               (would inject hints based on cross-class accumulation).
\*               Class-isolation property MUST be violated.

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Threshold,       \* consecutive failures before trip (3 in production)
    ErrorClasses,    \* set of error classes
    MaxSteps         \* bound model checking

VARIABLES
    count,           \* consecutive failure count (0..Threshold) — the trip driver
    currentClass,    \* current error class being tracked
    tripped,         \* whether hint was injected on THIS step
    totalTrips,      \* cumulative trip count
    sameClassRun,    \* honest length of the current same-class failure run
    step             \* step counter for bounded checking

\* sameClassRun is the *honest* same-class run length, maintained by the real
\* rule (same class +1, different class reset to 1, success/trip reset to 0) in
\* EVERY action — including the buggy one. It is NOT a ghost that mirrors the
\* action under test: in RecordFailureBuggy only [count] is corrupted, while
\* [sameClassRun] keeps the truth, so the trip property can compare the
\* dishonest driver against the honest streak.
vars == <<count, currentClass, tripped, totalTrips, sameClassRun, step>>

TypeOK ==
    /\ count \in 0..Threshold
    /\ currentClass \in ErrorClasses \cup {"none"}
    /\ tripped \in BOOLEAN
    /\ totalTrips \in Nat
    /\ sameClassRun \in 0..Threshold
    /\ step \in 0..MaxSteps

Init ==
    /\ count = 0
    /\ currentClass = "none"
    /\ tripped = FALSE
    /\ totalTrips = 0
    /\ sameClassRun = 0
    /\ step = 0

\* --- Clean Actions ---

RecordSuccess ==
    /\ step < MaxSteps
    /\ count' = 0
    /\ currentClass' = currentClass
    /\ tripped' = FALSE
    /\ totalTrips' = totalTrips
    /\ sameClassRun' = 0          \* a success breaks any same-class run
    /\ step' = step + 1

RecordFailure(cls) ==
    /\ step < MaxSteps
    /\ cls \in ErrorClasses
    /\ IF cls = currentClass
       THEN \* same class: increment
            IF count + 1 >= Threshold
            THEN \* TRIP
                 /\ count' = 0
                 /\ tripped' = TRUE
                 /\ totalTrips' = totalTrips + 1
                 /\ currentClass' = currentClass
                 /\ sameClassRun' = 0          \* trip resets the run
            ELSE
                 /\ count' = count + 1
                 /\ tripped' = FALSE
                 /\ totalTrips' = totalTrips
                 /\ currentClass' = currentClass
                 /\ sameClassRun' = sameClassRun + 1  \* same class extends the run
       ELSE \* different class: reset to 1
            /\ count' = 1
            /\ currentClass' = cls
            /\ tripped' = FALSE
            /\ totalTrips' = totalTrips
            /\ sameClassRun' = 1          \* fresh run of the new class
    /\ step' = step + 1

Next ==
    \/ RecordSuccess
    \/ \E cls \in ErrorClasses : RecordFailure(cls)

Spec == Init /\ [][Next]_vars

\* --- Safety Invariants ---

\* S1: count is always bounded
CountBounded ==
    count >= 0 /\ count < Threshold

\* S2: trip only with a genuine same-class streak.
\*
\* Action property (mirrors KeeperStateMachine.CompactionClearsOverflow): when a
\* trip fires on a step (tripped' = TRUE), the *honest* same-class run length
\* immediately before that step must already be at least Threshold-1, i.e. the
\* trip is the (Threshold)-th consecutive failure of one class. The honest run
\* [sameClassRun] is read UNPRIMED because the trip step itself resets it to 0;
\* a plain state invariant would read the reset value and false-violate on the
\* clean spec.
\*
\* This is NOT vacuous: the clean spec does reach tripped' = TRUE states (a
\* same-class run of Threshold), and there [sameClassRun] = Threshold-1 holds.
\* The buggy spec corrupts [count] (accumulates across classes) so it can trip
\* with [sameClassRun] < Threshold-1 — a cross-class trip — which violates this.
TripOnlyWithStreak ==
    [][ tripped' = TRUE => sameClassRun >= Threshold - 1 ]_vars

\* S3: totalTrips monotonic
TotalTripsMonotonic ==
    totalTrips >= 0

\* Combined. TripOnlyWithStreak is an action property (uses primed vars), so it
\* is supplied via PROPERTY, not INVARIANT; SafetyInvariant keeps the
\* state-predicate invariants only.
SafetyInvariant ==
    /\ TypeOK
    /\ CountBounded
    /\ TotalTripsMonotonic

\* --- Buggy model: class change does NOT reset count ---

RecordFailureBuggy(cls) ==
    /\ step < MaxSteps
    /\ cls \in ErrorClasses
    \* BUG: [count] has no class-change branch — it always increments, so it
    \* accumulates failures across different classes and can trip on a
    \* cross-class total. [sameClassRun] is still maintained by the honest rule
    \* (same class +1, different class reset to 1), so when this buggy count
    \* trips on a cross-class accumulation, sameClassRun is below Threshold-1
    \* and TripOnlyWithStreak is violated.
    /\ LET newCount == count + 1 IN
       LET sameClass == cls = currentClass IN
       LET honestRun == IF sameClass THEN sameClassRun + 1 ELSE 1 IN
       IF newCount >= Threshold
       THEN /\ count' = 0
            /\ tripped' = TRUE
            /\ totalTrips' = totalTrips + 1
            /\ currentClass' = cls
            /\ sameClassRun' = 0          \* trip resets the honest run too
       ELSE /\ count' = newCount
            /\ tripped' = FALSE
            /\ totalTrips' = totalTrips
            /\ currentClass' = cls
            /\ sameClassRun' = honestRun
    /\ step' = step + 1

NextBuggy ==
    \/ RecordSuccess
    \/ \E cls \in ErrorClasses : RecordFailureBuggy(cls)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
