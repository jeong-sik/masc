---- MODULE CascadeAttemptLiveness ----
\* Per-attempt streaming liveness FSM for the cascade layer (RFC-0022).
\*
\* Spec lifted from RFC-0022 §5.2.  RFC source:
\*   docs/rfc/RFC-0022-cascade-attempt-liveness.md (lines 292-348)
\*
\* OCaml ↔ TLA+ mapping:
\*
\*   spec variable / action  | OCaml location                                      | semantic
\*   ------------------------+-----------------------------------------------------+----------
\*   state                   | lib/cascade/cascade_attempt_liveness.ml:state       | { Awaiting | Streaming { _ } | Failed _ | Completed }
\*   last_chunk_at           | lib/cascade/cascade_attempt_liveness.ml:state       | inner field of [Streaming { last_chunk_at }]
\*   started_at              | lib/cascade/cascade_attempt_liveness.ml:state       | inner field of [Awaiting / Streaming { started_at }]
\*   now                     | (caller-supplied [Tick now] event)                  | wall clock, monotonic
\*   TTFT_MAX                | lib/cascade/cascade_attempt_liveness.ml:budget      | [budget.first_token_max]
\*   IDLE_MAX                | same                                                | [budget.inter_chunk_max]
\*   WALL_MAX                | same                                                | [budget.attempt_wall_max]
\*   Tick                    | step ~ Tick now                                     | clock fiber emission
\*   Chunk("Done")           | step ~ Chunk { kind = Done; received_at = _ }       | streaming complete
\*   Chunk(other)            | step ~ Chunk { kind = Text|Thinking|... }           | streaming progress (T1)
\*   LivenessKill            | step output Outcome { failure = ... }               | Off/Observe/Enforce dispatched downstream
\*
\* Bug Model (per CLAUDE.md TLA+ Bug Model Pattern):
\*   Clean cfg : INVARIANT KillIsJustified must hold under Spec.
\*   Buggy cfg : SpecBuggy admits BugChunk(k) — chunk events that DO arrive
\*               (real_last_chunk_at advances) but FAIL to update last_chunk_at
\*               (the bookkeeping bug).  This causes a spurious "idle" kill
\*               at a wall-clock time when the real chunk stream is fresh,
\*               violating KillIsJustified.
\*
\* Why the RFC's verbatim LivenessKillsFastEnough is not the chosen invariant:
\*   That invariant captures an *upper bound* on time-to-kill, but the bug
\*   we want to catch is "kill fires *too early* under spurious idle".  The
\*   bug is unsafe in the false-positive direction, not the late direction.
\*   KillIsJustified asserts that whenever the FSM transitions to Failed
\*   via the idle branch, a real idle period actually elapsed — which the
\*   bookkeeping bug breaks.
\*
\* Bounded model:
\*   `now` and `step` advance independently.  Tick increments both `now`
\*   and `step`; Chunk/BugChunk/LivenessKill increment only `step`.
\*   This keeps the model finite and lets TLC explore concurrent traces.
\*
\* Scope projection (chunk kinds):
\*   We model two kinds {"Text", "Done"}.  OCaml variants
\*   [Thinking | Tool_event | Heartbeat] all behave identically to [Text]
\*   at the FSM level (Invariant T1 — thinking counts as motion), so
\*   collapsing them is sound.

EXTENDS Integers, Sequences, FiniteSets

CONSTANTS
    TTFT_MAX,       \* time-to-first-token budget (RFC §4.1)
    IDLE_MAX,       \* inter-chunk idle budget
    WALL_MAX,       \* attempt wall-clock budget
    NOW_MAX,        \* upper bound on now for finite model
    MaxSteps,       \* upper bound on action count (orthogonal to NOW_MAX)
    ChunkKinds      \* abstract chunk kinds (e.g. {"Text", "Done"})

VARIABLES
    state,                  \* "Awaiting" | "Streaming" | "Failed" | "Success"
    last_chunk_at,          \* time of most recent advancing chunk (FSM-visible)
    real_last_chunk_at,     \* ghost: time of most recent chunk that ACTUALLY arrived
                            \* (under clean Spec equals last_chunk_at; under SpecBuggy
                            \* diverges when BugChunk fires)
    started_at,             \* attempt start time
    now,                    \* monotonic clock
    step,                   \* bounded action counter
    kill_reason             \* ghost: which tier triggered LivenessKill
                            \* "none" | "ttft" | "idle" | "wall"

vars == <<state, last_chunk_at, real_last_chunk_at, started_at, now, step, kill_reason>>

\* TLA+ has no built-in Max; provide one over two integers.
Max2(a, b) == IF a >= b THEN a ELSE b

TypeOK ==
    /\ state \in {"Awaiting", "Streaming", "Failed", "Success"}
    /\ last_chunk_at \in 0..NOW_MAX
    /\ real_last_chunk_at \in 0..NOW_MAX
    /\ started_at \in 0..NOW_MAX
    /\ now \in 0..NOW_MAX
    /\ step \in 0..MaxSteps
    /\ kill_reason \in {"none", "ttft", "idle", "wall"}

Init ==
    /\ state = "Awaiting"
    /\ last_chunk_at = 0
    /\ real_last_chunk_at = 0
    /\ started_at = 0
    /\ now = 0
    /\ step = 0
    /\ kill_reason = "none"

\* --- Clean Actions ---

Tick ==
    /\ step < MaxSteps
    /\ now < NOW_MAX
    /\ state \in {"Awaiting", "Streaming"}  \* terminal states absorb time
    /\ now' = now + 1
    /\ step' = step + 1
    /\ UNCHANGED <<state, last_chunk_at, real_last_chunk_at, started_at, kill_reason>>

\* Streaming chunk that advances liveness (Invariants S1, T1).
\* Done is terminal (Invariant S2).
\* Both last_chunk_at AND real_last_chunk_at advance — this is the *clean*
\* contract.  The bug below will keep real_last_chunk_at honest while
\* leaving last_chunk_at stale.
Chunk(kind) ==
    /\ step < MaxSteps
    /\ state \in {"Awaiting", "Streaming"}
    /\ kind \in ChunkKinds
    /\ state' = (IF kind = "Done" THEN "Success" ELSE "Streaming")
    /\ last_chunk_at' = now
    /\ real_last_chunk_at' = now
    /\ step' = step + 1
    /\ UNCHANGED <<started_at, now, kill_reason>>

\* Liveness kill — three tiers from RFC §4.1.
\* Each branch records the reason in the ghost variable for the safety check.
LivenessKill ==
    /\ step < MaxSteps
    /\ \/ /\ state = "Awaiting"
          /\ now - started_at >= TTFT_MAX
          /\ kill_reason' = "ttft"
       \/ /\ state = "Streaming"
          /\ now - last_chunk_at >= IDLE_MAX
          /\ kill_reason' = "idle"
       \/ /\ state = "Streaming"
          /\ now - started_at >= WALL_MAX
          /\ kill_reason' = "wall"
    /\ state' = "Failed"
    /\ step' = step + 1
    /\ UNCHANGED <<last_chunk_at, real_last_chunk_at, started_at, now>>

Next ==
    \/ Tick
    \/ \E k \in ChunkKinds : Chunk(k)
    \/ LivenessKill

Spec == Init /\ [][Next]_vars

\* --- Safety Invariant — every kill must be *justified* by reality.
\*
\* Under clean Spec, real_last_chunk_at = last_chunk_at always, so the
\* kill triggers (now-last_chunk_at >= IDLE_MAX, now-started_at >= TTFT_MAX,
\* now-started_at >= WALL_MAX) directly imply the corresponding "real"
\* condition.  Under SpecBuggy, BugChunk lets last_chunk_at lag behind
\* real_last_chunk_at, so the FSM-visible condition can fire while the
\* "real" condition does not — a false-positive kill.
KillIsJustified ==
    \/ kill_reason = "none"
    \/ /\ kill_reason = "ttft" /\ now - started_at >= TTFT_MAX
    \/ /\ kill_reason = "idle" /\ now - real_last_chunk_at >= IDLE_MAX
    \/ /\ kill_reason = "wall" /\ now - started_at >= WALL_MAX

\* The RFC §5.2 verbatim invariant `LivenessKillsFastEnough` is documented
\* in the RFC but is NOT used as a TLC invariant here, because it requires
\* a fairness assumption (`WF_vars(LivenessKill)`) to hold under TLA+
\* model checking — without fairness, TLC can construct traces where
\* LivenessKill is enabled but indefinitely deferred in favour of Tick.
\* The OCaml implementation enforces fairness via the per-attempt clock
\* fiber that runs `step` on every tick (PR-3 wiring); the spec's job
\* here is to verify the *bug-distinguishing* property KillIsJustified.
\* Future work: re-introduce LivenessKillsFastEnough under SF/WF when the
\* repo gains a convention for fairness-paired specs.

SafetyInvariant ==
    /\ TypeOK
    /\ KillIsJustified

\* --- Bug Model: chunk events that fail to update FSM bookkeeping ---
\*
\* This models the production bug RFC §5 calls out: a chunk arrives at the
\* MASC adapter (so real_last_chunk_at advances) but the FSM's last_chunk_at
\* is not updated (e.g. the [record_progress] call is missing on a code
\* path).  The FSM continues to perceive idle, and the idle branch of
\* LivenessKill fires spuriously while the real chunk stream is fresh.
BugChunk(kind) ==
    /\ step < MaxSteps
    /\ state \in {"Awaiting", "Streaming"}
    /\ kind \in ChunkKinds
    /\ kind /= "Done"  \* the bug only affects progress events, not termination
    /\ state' = "Streaming"
    /\ real_last_chunk_at' = now  \* real chunk DID arrive
    /\ UNCHANGED last_chunk_at    \* the bug — FSM bookkeeping missed it
    /\ step' = step + 1
    /\ UNCHANGED <<started_at, now, kill_reason>>

NextBuggy ==
    \/ Tick
    \/ \E k \in ChunkKinds : Chunk(k)
    \/ \E k \in ChunkKinds : BugChunk(k)
    \/ LivenessKill

SpecBuggy == Init /\ [][NextBuggy]_vars

====
