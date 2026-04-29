---- MODULE AuditLogAppendOrder ----
\* Boundary spec for Dated_jsonl.append mutex exclusion
\* (lib/dated_jsonl/dated_jsonl.ml:212-214).
\*
\* Source:
\*   let append t json =
\*     let mutex = Atomic.get t.mutex in
\*     Eio.Mutex.use_rw ~protect:false mutex (fun () -> ...)
\*
\* The .mli (lib/dated_jsonl/dated_jsonl.mli:18-20) advertises:
\*   "Append [json] to today's [DD.jsonl] inside [YYYY-MM/].
\*    Creates directories as needed.  Thread-safe via internal mutex."
\*
\* This spec encodes the thread-safety contract in finite state:
\* under the mutex, exactly one fiber can be inside the critical
\* section that touches the JSONL file.  The buggy variant strips
\* the mutex so a fiber enters the CS without acquiring, violating
\* MutexExclusion.
\*
\* Phase 2 of #11655 (the boundary spec for audit_log).  Phase 1
\* covered cache-install (AuditLog.tla, MERGED in PR #11960).  This
\* spec covers append-time mutex exclusion.  DurableBeforeAck (Phase 3)
\* will need an explicit fsync/flush model and is left to a follow-up.
\*
\* Bug Model (memory: TLA+ Bug Model pattern):
\*   Spec       (clean): Acquire then ReleaseAndAppend in sequence;
\*                       inside has cardinality <= 1 throughout.
\*   SpecBuggy: AppendBypass enters CS without acquire ->
\*              two fibers inside -> MutexExclusion violated.
\*
\* Reference: issue #11655 (follow-up of #11522 Phase 4 MED2),
\* memory: feedback_TLA-Bug-Model-pattern.

EXTENDS TLC, Naturals, FiniteSets

CONSTANTS Fibers   \* set of concurrent fibers, e.g. {1, 2}

VARIABLES
    mu_held,    \* 0 = free, 1 = some fiber holds the mutex
    inside,     \* set of fiber ids currently inside the critical section
    log_len,    \* number of completed appends
    pc          \* per-fiber program counter

vars == <<mu_held, inside, log_len, pc>>

PCStates == {"Idle", "Holding", "Done"}

\* Bound the state space for TLC.
MaxAppends == Cardinality(Fibers)

TypeOK ==
    /\ mu_held \in 0..1
    /\ inside \subseteq Fibers
    /\ log_len \in 0..MaxAppends
    /\ pc \in [Fibers -> PCStates]

Init ==
    /\ mu_held = 0
    /\ inside = {}
    /\ log_len = 0
    /\ pc = [f \in Fibers |-> "Idle"]

\* Clean: acquire the mutex.  Mirrors [Eio.Mutex.use_rw] entering its
\* critical section.  The acquire fails if already held -- that
\* encodes the blocking semantics: another fiber must release first.
Acquire(f) ==
    /\ pc[f] = "Idle"
    /\ mu_held = 0
    /\ mu_held' = 1
    /\ inside' = inside \cup {f}
    /\ pc' = [pc EXCEPT ![f] = "Holding"]
    /\ UNCHANGED <<log_len>>

\* Clean: append within the critical section, then release.  Models
\* the body of [Eio.Mutex.use_rw ~protect:false ...].
ReleaseAndAppend(f) ==
    /\ pc[f] = "Holding"
    /\ mu_held' = 0
    /\ inside' = inside \ {f}
    /\ log_len' = log_len + 1
    /\ pc' = [pc EXCEPT ![f] = "Done"]

Next ==
    \/ \E f \in Fibers : Acquire(f)
    \/ \E f \in Fibers : ReleaseAndAppend(f)

Spec == Init /\ [][Next]_vars

\* ── Invariants ──────────────────────────────────────────────────

\* MutexExclusion (the source-declared invariant): at most one fiber
\* inside the critical section at any time.  Direct encoding of the
\* "Thread-safe via internal mutex" contract on Dated_jsonl.append.
MutexExclusion ==
    Cardinality(inside) <= 1

\* ── Bug actions (used only by SpecBuggy) ────────────────────────

\* B1 AppendBypass.  Refactor strips the [Eio.Mutex.use_rw] wrapper.
\* A fiber enters the critical section without acquiring the mutex,
\* and the spec's mutex flag is left in its previous state.  When two
\* fibers fire AppendBypass in succession (or one fires while another
\* legitimately holds), [inside] grows past 1 and MutexExclusion
\* fails within <=2 steps.
AppendBypass(f) ==
    /\ pc[f] = "Idle"
    /\ inside' = inside \cup {f}
    /\ pc' = [pc EXCEPT ![f] = "Holding"]
    /\ UNCHANGED <<mu_held, log_len>>

NextBuggy ==
    \/ Next
    \/ \E f \in Fibers : AppendBypass(f)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
