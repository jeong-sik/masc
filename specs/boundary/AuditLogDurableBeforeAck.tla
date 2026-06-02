---- MODULE AuditLogDurableBeforeAck ----
\* Boundary spec for the "durable before ack" contract on
\* Dated_jsonl.append.
\*
\* The implicit operator expectation when an audit_log.append call
\* returns successfully is "the entry has reached disk and survives
\* a crash".  Without an explicit fsync between the buffered write
\* and the caller-visible return, this expectation is fragile.  The
\* spec encodes the contract:
\*
\*     acked entries are a subset of on-disk entries
\*
\* and the bug variant exposes the gap:
\*
\*     AckBeforeFlush -- caller is told success while the entry is
\*     still in the kernel page cache, never fsynced.
\*
\* Phase 3 of #11655.  Phases 1 (CacheConsistency, PR #11960) and 2
\* (MutexExclusion, PR #11982) covered the in-memory race classes.
\* This phase makes the durability contract explicit so future
\* implementation work (fsync injection, batched fsync) has a
\* regression gate.
\*
\* Bug Model (memory: TLA+ Bug Model pattern):
\*   Spec       (clean): Append -> Flush -> Ack in order.
\*                       acked \subseteq on_disk maintained.
\*   SpecBuggy: AckBeforeFlush short-circuits Flush ->
\*              acked \ on_disk \neq {} -> Durability violated.
\*
\* Reference: issue #11655 Phase 3, follow-up of #11522 Phase 4 MED2.

EXTENDS TLC, Naturals, FiniteSets

CONSTANTS Fibers   \* set of concurrent fibers

VARIABLES
    on_disk,     \* set of entry ids that have been fsynced to disk
    acked,       \* set of entry ids that have been acked to the caller
    next_id,     \* monotonic id supply
    fiber_entry, \* per-fiber working entry id (0 = none)
    pc           \* per-fiber program counter

vars == <<on_disk, acked, next_id, fiber_entry, pc>>

PCStates == {"Idle", "Buffered", "Flushed", "Acked"}

NoEntry == 0

\* Bound state space for TLC.
MaxAppends == Cardinality(Fibers)

TypeOK ==
    /\ on_disk \subseteq 1..MaxAppends
    /\ acked \subseteq 1..MaxAppends
    /\ next_id \in 1..(MaxAppends + 1)
    /\ fiber_entry \in [Fibers -> 0..MaxAppends]
    /\ pc \in [Fibers -> PCStates]

Init ==
    /\ on_disk = {}
    /\ acked = {}
    /\ next_id = 1
    /\ fiber_entry = [f \in Fibers |-> NoEntry]
    /\ pc = [f \in Fibers |-> "Idle"]

\* Clean: caller invokes append.  An entry id is allocated; the entry
\* is written to the kernel buffer (in-memory).  Not yet on disk.
AppendStart(f) ==
    /\ pc[f] = "Idle"
    /\ next_id <= MaxAppends
    /\ fiber_entry' = [fiber_entry EXCEPT ![f] = next_id]
    /\ next_id' = next_id + 1
    /\ pc' = [pc EXCEPT ![f] = "Buffered"]
    /\ UNCHANGED <<on_disk, acked>>

\* Clean: explicit fsync (or equivalent durability barrier) lands the
\* entry on disk.  The model treats this as atomic.
AppendFlush(f) ==
    /\ pc[f] = "Buffered"
    /\ on_disk' = on_disk \cup {fiber_entry[f]}
    /\ pc' = [pc EXCEPT ![f] = "Flushed"]
    /\ UNCHANGED <<acked, next_id, fiber_entry>>

\* Clean: only after Flush does the caller see success.
AppendAck(f) ==
    /\ pc[f] = "Flushed"
    /\ acked' = acked \cup {fiber_entry[f]}
    /\ pc' = [pc EXCEPT ![f] = "Acked"]
    /\ UNCHANGED <<on_disk, next_id, fiber_entry>>

Next ==
    \/ \E f \in Fibers : AppendStart(f)
    \/ \E f \in Fibers : AppendFlush(f)
    \/ \E f \in Fibers : AppendAck(f)

Spec == Init /\ [][Next]_vars

\* ── Invariants ──────────────────────────────────────────────────

\* Durability (the contract): every acked entry is on disk.
\* If the implementation lacks fsync between buffered-write and
\* caller-return, this fails.
Durability ==
    acked \subseteq on_disk

\* ── Bug actions (used only by SpecBuggy) ────────────────────────

\* B1 AckBeforeFlush.  Refactor (or current state of the code) acks
\* the caller while the entry is still in the buffer, never fsynced.
\* Direct violation of Durability: an entry shows up in [acked] but
\* not in [on_disk].
AckBeforeFlush(f) ==
    /\ pc[f] = "Buffered"
    /\ acked' = acked \cup {fiber_entry[f]}
    /\ pc' = [pc EXCEPT ![f] = "Acked"]
    /\ UNCHANGED <<on_disk, next_id, fiber_entry>>

NextBuggy ==
    \/ Next
    \/ \E f \in Fibers : AckBeforeFlush(f)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
