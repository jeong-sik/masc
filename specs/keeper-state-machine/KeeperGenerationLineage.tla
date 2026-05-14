---- MODULE KeeperGenerationLineage ----
\* Bounded lineage contract for keeper post-turn handoff rollover.
\*
\* Scope:
\*   - same keeper identity across generations
\*   - trace_id replacement on successful handoff
\*   - trace_history append-only ancestry
\*   - checkpoint lineage parity once the keeper returns to idle
\*
\* Modeled from:
\*   - lib/keeper/keeper_post_turn.ml
\*   - lib/keeper/keeper_rollover.ml
\*   - lib/keeper/keeper_types.mli
\*
\* Out of scope:
\*   - compaction strategy selection
\*   - tool execution / Agent.run turn loop
\*   - long-term memory recall semantics
\*
\* This spec mirrors the current OCaml meaning of generation:
\*   "same keeper, new trace" rather than a new child runtime.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Keepers,       \* finite keeper names
    MaxHandoffs    \* small bound for TLC

VARIABLES
    keeper_phase,      \* [Keepers -> {"idle","running","handing_off"}]
    generation,        \* [Keepers -> 0..MaxHandoffs]
    current_trace_id,  \* [Keepers -> Nat]
    trace_history,     \* [Keepers -> Seq(Nat)] oldest -> newest
    ckpt_valid,        \* [Keepers -> BOOLEAN]
    ckpt_generation,   \* [Keepers -> Nat]
    ckpt_trace_id,     \* [Keepers -> Nat]
    next_trace_id      \* fresh trace allocator

vars ==
    << keeper_phase, generation, current_trace_id, trace_history,
       ckpt_valid, ckpt_generation, ckpt_trace_id, next_trace_id >>

\* Issue #8642/#8701 family: explicit OCaml ↔ TLA+ mapping. SSOT for
\* OCaml side is lib/keeper/keeper_state_machine.ml (13 phases;
\* Zombie added iter 4 #14707, terminal-terminal, not modeled here).
\* This spec uses the smallest possible alphabet (3 symbols) because the
\* generation-lineage contract only inspects whether the keeper is
\* idle, actively executing, or rolling over a generation handoff.
\*
\* Mapping (#8979: spec-internal abstract names — do NOT match
\* phase_to_string output verbatim; "idle" is an abstraction over
\* Offline, not the wire string "offline"):
\*
\*   spec name      ↔ OCaml constructor      (phase_to_string output)
\*   ---------------+-------------------------+----------------------
\*   "idle"         ↔ Offline                  ("offline")
\*   "running"      ↔ Running                  ("running")
\*   "handing_off"  ↔ HandingOff               ("handing_off")
\*
\* If trace-driven model checking is later added, the spec strings
\* would need to be renamed to match the wire format ("offline" instead
\* of "idle").  Until then, treat the table above as the authoritative
\* abstraction function.
\*
\* Unmodeled here (covered in companion specs):
\*   Failing, Overflowed, Compacting, Draining, Paused,
\*   Stopped, Crashed, Restarting, Dead, Zombie — see
\*   KeeperReconcileLiveness.tla and KeeperContextLifecycle.tla.
\*   Zombie is terminal-terminal (post-Dead, no generation events
\*   reachable); safety surface lives in KeeperStateMachine.tla
\*   (ZombieIsForever / ZombieRequiresTerminalFailureLatched).
Phases == {"idle", "running", "handing_off"}

SeqElems(seq) == {seq[i] : i \in 1..Len(seq)}

NoDuplicates(seq) == Len(seq) = Cardinality(SeqElems(seq))

Init ==
    /\ keeper_phase = [k \in Keepers |-> "idle"]
    /\ generation = [k \in Keepers |-> 0]
    /\ current_trace_id \in [Keepers -> 1..Cardinality(Keepers)]
    /\ \A k1, k2 \in Keepers : k1 /= k2 => current_trace_id[k1] /= current_trace_id[k2]
    /\ trace_history = [k \in Keepers |-> <<>>]
    /\ ckpt_valid = [k \in Keepers |-> FALSE]
    /\ ckpt_generation = [k \in Keepers |-> 0]
    /\ ckpt_trace_id = [k \in Keepers |-> 0]
    /\ next_trace_id = Cardinality(Keepers) + 1

TypeOK ==
    /\ keeper_phase \in [Keepers -> Phases]
    /\ generation \in [Keepers -> 0..MaxHandoffs]
    /\ current_trace_id \in [Keepers -> Nat]
    /\ trace_history \in [Keepers -> Seq(Nat)]
    /\ \A k \in Keepers : Len(trace_history[k]) <= MaxHandoffs
    /\ ckpt_valid \in [Keepers -> BOOLEAN]
    /\ ckpt_generation \in [Keepers -> Nat]
    /\ ckpt_trace_id \in [Keepers -> Nat]
    /\ next_trace_id \in Nat

StartTurn(k) ==
    /\ keeper_phase[k] = "idle"
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "running"]
    /\ UNCHANGED <<generation, current_trace_id, trace_history,
                   ckpt_valid, ckpt_generation, ckpt_trace_id, next_trace_id>>

FinishTurnNoHandoff(k) ==
    /\ keeper_phase[k] = "running"
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "idle"]
    /\ ckpt_valid' = [ckpt_valid EXCEPT ![k] = TRUE]
    /\ ckpt_generation' = [ckpt_generation EXCEPT ![k] = generation[k]]
    /\ ckpt_trace_id' = [ckpt_trace_id EXCEPT ![k] = current_trace_id[k]]
    /\ UNCHANGED <<generation, current_trace_id, trace_history, next_trace_id>>

HandoffStarted(k) ==
    /\ keeper_phase[k] = "running"
    /\ generation[k] < MaxHandoffs
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "handing_off"]
    /\ UNCHANGED <<generation, current_trace_id, trace_history,
                   ckpt_valid, ckpt_generation, ckpt_trace_id, next_trace_id>>

HandoffCompleted(k) ==
    /\ keeper_phase[k] = "handing_off"
    /\ generation[k] < MaxHandoffs
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "idle"]
    /\ generation' = [generation EXCEPT ![k] = generation[k] + 1]
    /\ trace_history' =
         [trace_history EXCEPT ![k] = Append(trace_history[k], current_trace_id[k])]
    /\ current_trace_id' = [current_trace_id EXCEPT ![k] = next_trace_id]
    /\ ckpt_valid' = [ckpt_valid EXCEPT ![k] = TRUE]
    /\ ckpt_generation' = [ckpt_generation EXCEPT ![k] = generation[k] + 1]
    /\ ckpt_trace_id' = [ckpt_trace_id EXCEPT ![k] = next_trace_id]
    /\ next_trace_id' = next_trace_id + 1

HandoffFailed(k) ==
    /\ keeper_phase[k] = "handing_off"
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "idle"]
    /\ ckpt_valid' = [ckpt_valid EXCEPT ![k] = TRUE]
    /\ ckpt_generation' = [ckpt_generation EXCEPT ![k] = generation[k]]
    /\ ckpt_trace_id' = [ckpt_trace_id EXCEPT ![k] = current_trace_id[k]]
    /\ UNCHANGED <<generation, current_trace_id, trace_history, next_trace_id>>

\* Deliberate bug: generation increments and a new trace is allocated,
\* but the previous trace is not appended to ancestry and the checkpoint
\* still points at the old generation. This breaks keeper_rollover parity.
HandoffCompletedBuggy(k) ==
    /\ keeper_phase[k] = "handing_off"
    /\ generation[k] < MaxHandoffs
    /\ keeper_phase' = [keeper_phase EXCEPT ![k] = "idle"]
    /\ generation' = [generation EXCEPT ![k] = generation[k] + 1]
    /\ trace_history' = trace_history
    /\ current_trace_id' = [current_trace_id EXCEPT ![k] = next_trace_id]
    /\ ckpt_valid' = [ckpt_valid EXCEPT ![k] = TRUE]
    /\ ckpt_generation' = [ckpt_generation EXCEPT ![k] = generation[k]]
    /\ ckpt_trace_id' = [ckpt_trace_id EXCEPT ![k] = current_trace_id[k]]
    /\ next_trace_id' = next_trace_id + 1

Next ==
    \E k \in Keepers :
        \/ StartTurn(k)
        \/ FinishTurnNoHandoff(k)
        \/ HandoffStarted(k)
        \/ HandoffCompleted(k)
        \/ HandoffFailed(k)

NextBuggy ==
    \E k \in Keepers :
        \/ StartTurn(k)
        \/ FinishTurnNoHandoff(k)
        \/ HandoffStarted(k)
        \/ HandoffCompletedBuggy(k)
        \/ HandoffFailed(k)

HandoffResolves(k) == HandoffCompleted(k) \/ HandoffFailed(k)

Fairness ==
    \A k \in Keepers : WF_vars(HandoffResolves(k))

Spec == Init /\ [][Next]_vars /\ Fairness
SpecBuggy == Init /\ [][NextBuggy]_vars /\ Fairness

CurrentTraceIsolation ==
    \A k1, k2 \in Keepers :
        k1 /= k2 => current_trace_id[k1] /= current_trace_id[k2]

GenerationMatchesHistory ==
    \A k \in Keepers : generation[k] = Len(trace_history[k])

CurrentTraceNotInHistory ==
    \A k \in Keepers : current_trace_id[k] \notin SeqElems(trace_history[k])

TraceHistoryUnique ==
    \A k \in Keepers : NoDuplicates(trace_history[k])

TraceIdsAllocated ==
    /\ \A k \in Keepers : current_trace_id[k] > 0 /\ current_trace_id[k] < next_trace_id
    /\ \A k \in Keepers : \A t \in SeqElems(trace_history[k]) : t > 0 /\ t < next_trace_id

IdleCheckpointMatchesCommittedLineage ==
    \A k \in Keepers :
        (keeper_phase[k] = "idle" /\ ckpt_valid[k]) =>
            /\ ckpt_generation[k] = generation[k]
            /\ ckpt_trace_id[k] = current_trace_id[k]

HandoffEventuallyResolves ==
    \A k \in Keepers :
        (keeper_phase[k] = "handing_off") ~> (keeper_phase[k] = "idle")

====
