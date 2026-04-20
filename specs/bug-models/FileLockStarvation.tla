---- MODULE FileLockStarvation ----
\* Bug Model: File lock prune-while-held creates duplicate mutex.
\*
\* Models lib/process/file_lock_eio.ml: get_entry + prune_stale_entries.
\*
\* Lock acquisition order: table_mu -> per-path Eio.Mutex -> Unix.flock
\*
\* Bug scenario:
\*   1. Fiber A: get_entry("foo") returns mu1, acquires mu1, acquires flock
\*      (doing slow work, last_used becomes stale)
\*   2. Fiber B: get_entry("bar") triggers prune_stale_entries,
\*      removes mu1 from table (last_used too old)
\*   3. Fiber C: get_entry("foo") creates NEW mu2 for same path,
\*      acquires mu2 (different mutex!), tries flock -> blocked by A
\*
\* After prune: two Eio.Mutexes exist for the same path.
\* Eio-level serialization is broken (fibers use different mutexes).
\* The Unix flock is the last line of defense.
\*
\* If flock is not used (with_mutex path only), data corruption is possible.
\*
\* Actual code (verified 2026-04-20):
\*   lib/process/file_lock_eio.ml:52   prune_stale_entries (under table_mu)
\*   lib/process/file_lock_eio.ml:68   get_entry (formerly get_lock; creates
\*                                     new entry if absent)
\*   lib/process/file_lock_eio.ml:84   release_entry (counterpart to get_entry)
\*   lib/process/file_lock_eio.ml:170  with_mutex — uses Eio.Mutex ONLY, no flock
\*   lib/process/file_lock_eio.ml:180  with_lock — Eio.Mutex + Unix flock
\*
\* (Path drift: lib/file_lock_eio.ml -> lib/process/file_lock_eio.ml.
\*  Symbol drift: get_lock -> get_entry + release_entry pair.
\*  Recorded for cross-reference.)

EXTENDS Naturals

CONSTANTS
    NumFibers   \* Number of concurrent fibers (e.g. 3)

VARIABLES
    \* Per-fiber state
    fiber_state,    \* [1..NumFibers] -> "idle" | "has_mu" | "has_flock" | "done"
    fiber_mu_id,    \* [1..NumFibers] -> 0..99 (which mutex generation)
    \* Table state
    table_mu_id,    \* Current mutex ID in table (0 = absent)
    table_last_used,\* "fresh" | "stale"
    next_mu_id,     \* Counter for generating unique mutex IDs
    \* Flock state
    flock_holder    \* 0 = free, 1..NumFibers = held by fiber

vars == <<fiber_state, fiber_mu_id, table_mu_id, table_last_used, next_mu_id, flock_holder>>

TypeOK ==
    /\ \A i \in 1..NumFibers :
        /\ fiber_state[i] \in {"idle", "has_mu", "has_flock", "done"}
        /\ fiber_mu_id[i] \in 0..99
    /\ table_mu_id \in 0..99
    /\ table_last_used \in {"fresh", "stale"}
    /\ next_mu_id \in 1..99
    /\ flock_holder \in 0..NumFibers

Init ==
    /\ fiber_state = [i \in 1..NumFibers |-> "idle"]
    /\ fiber_mu_id = [i \in 1..NumFibers |-> 0]
    /\ table_mu_id = 0
    /\ table_last_used = "fresh"
    /\ next_mu_id = 1
    /\ flock_holder = 0

\* ── Actions ─────────────────────────────────────

\* Fiber acquires per-path mutex via get_lock (creates if absent)
AcquireMutex(i) ==
    /\ fiber_state[i] = "idle"
    /\ IF table_mu_id = 0
       THEN \* Create new mutex
            /\ next_mu_id < 99
            /\ table_mu_id' = next_mu_id
            /\ next_mu_id' = next_mu_id + 1
            /\ fiber_mu_id' = [fiber_mu_id EXCEPT ![i] = next_mu_id]
            /\ table_last_used' = "fresh"
       ELSE \* Reuse existing
            /\ fiber_mu_id' = [fiber_mu_id EXCEPT ![i] = table_mu_id]
            /\ table_last_used' = "fresh"
            /\ UNCHANGED <<table_mu_id, next_mu_id>>
    /\ fiber_state' = [fiber_state EXCEPT ![i] = "has_mu"]
    /\ UNCHANGED flock_holder

\* Fiber acquires flock (only if free)
AcquireFlock(i) ==
    /\ fiber_state[i] = "has_mu"
    /\ flock_holder = 0
    /\ flock_holder' = i
    /\ fiber_state' = [fiber_state EXCEPT ![i] = "has_flock"]
    /\ UNCHANGED <<fiber_mu_id, table_mu_id, table_last_used, next_mu_id>>

\* Fiber releases both flock and mutex
Release(i) ==
    /\ fiber_state[i] = "has_flock"
    /\ flock_holder = i
    /\ flock_holder' = 0
    /\ fiber_state' = [fiber_state EXCEPT ![i] = "done"]
    /\ UNCHANGED <<fiber_mu_id, table_mu_id, table_last_used, next_mu_id>>

\* Reset fiber for next round
ResetFiber(i) ==
    /\ fiber_state[i] = "done"
    /\ fiber_state' = [fiber_state EXCEPT ![i] = "idle"]
    /\ fiber_mu_id' = [fiber_mu_id EXCEPT ![i] = 0]
    /\ UNCHANGED <<table_mu_id, table_last_used, next_mu_id, flock_holder>>

\* Time passes: last_used becomes stale
TimeAdvance ==
    /\ table_last_used = "fresh"
    /\ table_last_used' = "stale"
    /\ UNCHANGED <<fiber_state, fiber_mu_id, table_mu_id, next_mu_id, flock_holder>>

\* Prune removes stale entry from table (even if a fiber holds its mutex)
PruneStaleEntry ==
    /\ table_last_used = "stale"
    /\ table_mu_id > 0
    /\ table_mu_id' = 0     \* Entry removed
    /\ UNCHANGED <<fiber_state, fiber_mu_id, table_last_used, next_mu_id, flock_holder>>

Next ==
    \/ \E i \in 1..NumFibers :
        \/ AcquireMutex(i)
        \/ AcquireFlock(i)
        \/ Release(i)
        \/ ResetFiber(i)
    \/ TimeAdvance
    \/ PruneStaleEntry

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariants ───────────────────────────

\* Flock mutual exclusion (always holds due to OS guarantee)
FlockMutex ==
    \A i, j \in 1..NumFibers :
        (flock_holder = i /\ flock_holder = j) => i = j

\* Critical invariant: all fibers holding a mutex should reference
\* the SAME mutex ID (no duplicate mutexes for same path).
\* When prune removes the entry and a new one is created, fibers
\* may hold different mutex IDs -> Eio serialization broken.
SingleMutexPerPath ==
    \A i, j \in 1..NumFibers :
        (fiber_state[i] \in {"has_mu", "has_flock"} /\
         fiber_state[j] \in {"has_mu", "has_flock"} /\
         i # j) =>
            fiber_mu_id[i] = fiber_mu_id[j]

\* ── Bug Model ───────────────────────────────────

\* Clean model: prune never removes entries that are in use.
\* A fiber holding a mutex keeps it fresh.
PruneStaleEntryClean ==
    /\ table_last_used = "stale"
    /\ table_mu_id > 0
    \* Guard: no fiber currently holds a mutex with this ID
    /\ \A i \in 1..NumFibers :
        fiber_state[i] \in {"idle", "done"}
    /\ table_mu_id' = 0
    /\ UNCHANGED <<fiber_state, fiber_mu_id, table_last_used, next_mu_id, flock_holder>>

NextClean ==
    \/ \E i \in 1..NumFibers :
        \/ AcquireMutex(i)
        \/ AcquireFlock(i)
        \/ Release(i)
        \/ ResetFiber(i)
    \/ TimeAdvance
    \/ PruneStaleEntryClean

SpecClean == Init /\ [][NextClean]_vars /\ WF_vars(NextClean)
SpecBuggy == Init /\ [][Next]_vars /\ WF_vars(Next)

====
