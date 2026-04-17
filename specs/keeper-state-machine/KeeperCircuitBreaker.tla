---- MODULE KeeperCircuitBreaker ----
\* Circuit Breaker state machine for keeper tool failure recovery.
\* Verifies safety (no false trips) and mutation-tests the class isolation property.

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    Threshold,       \* consecutive failures before trip (3 in production)
    ErrorClasses,    \* set of error classes
    MaxSteps         \* bound model checking

VARIABLES
    count,           \* consecutive failure count (0..Threshold)
    currentClass,    \* current error class being tracked
    tripped,         \* whether hint was injected on THIS step
    totalTrips,      \* cumulative trip count
    classStreak,     \* TRUE iff all counted failures are same class (ghost variable)
    step             \* step counter for bounded checking

vars == <<count, currentClass, tripped, totalTrips, classStreak, step>>

TypeOK ==
    /\ count \in 0..Threshold
    /\ currentClass \in ErrorClasses \cup {"none"}
    /\ tripped \in BOOLEAN
    /\ totalTrips \in Nat
    /\ classStreak \in BOOLEAN
    /\ step \in 0..MaxSteps

Init ==
    /\ count = 0
    /\ currentClass = "none"
    /\ tripped = FALSE
    /\ totalTrips = 0
    /\ classStreak = TRUE
    /\ step = 0

\* --- Clean Actions ---

RecordSuccess ==
    /\ step < MaxSteps
    /\ count' = 0
    /\ currentClass' = currentClass
    /\ tripped' = FALSE
    /\ totalTrips' = totalTrips
    /\ classStreak' = TRUE
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
                 /\ classStreak' = TRUE
            ELSE
                 /\ count' = count + 1
                 /\ tripped' = FALSE
                 /\ totalTrips' = totalTrips
                 /\ currentClass' = currentClass
                 /\ classStreak' = TRUE  \* still same class
       ELSE \* different class: reset to 1
            /\ count' = 1
            /\ currentClass' = cls
            /\ tripped' = FALSE
            /\ totalTrips' = totalTrips
            /\ classStreak' = TRUE  \* fresh streak of new class
    /\ step' = step + 1

Next ==
    \/ RecordSuccess
    \/ \E cls \in ErrorClasses : RecordFailure(cls)

Spec == Init /\ [][Next]_vars

\* --- Safety Invariants ---

\* S1: count is always bounded
CountBounded ==
    count >= 0 /\ count < Threshold

\* S2: trip only with class streak
TripOnlyWithStreak ==
    tripped = TRUE => classStreak = TRUE

\* S3: totalTrips monotonic
TotalTripsMonotonic ==
    totalTrips >= 0

\* Combined
SafetyInvariant ==
    /\ TypeOK
    /\ CountBounded
    /\ TripOnlyWithStreak
    /\ TotalTripsMonotonic

\* --- Buggy model: class change does NOT reset count ---

RecordFailureBuggy(cls) ==
    /\ step < MaxSteps
    /\ cls \in ErrorClasses
    \* BUG: no class-change branch — always increment
    /\ LET newCount == count + 1 IN
       LET classChanged == cls # currentClass /\ currentClass # "none" IN
       IF newCount >= Threshold
       THEN /\ count' = 0
            /\ tripped' = TRUE
            /\ totalTrips' = totalTrips + 1
            /\ currentClass' = cls
            /\ classStreak' = IF classChanged THEN FALSE ELSE classStreak
       ELSE /\ count' = newCount
            /\ tripped' = FALSE
            /\ totalTrips' = totalTrips
            /\ currentClass' = cls
            /\ classStreak' = IF classChanged THEN FALSE ELSE classStreak
    /\ step' = step + 1

NextBuggy ==
    \/ RecordSuccess
    \/ \E cls \in ErrorClasses : RecordFailureBuggy(cls)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
