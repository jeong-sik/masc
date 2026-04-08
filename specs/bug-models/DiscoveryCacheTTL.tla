---- MODULE DiscoveryCacheTTL ----
\* Bug Model: Discovery cache Atomic TTL guard vs Mutex-protected data.
\*
\* Models discovery_cache.ml structural hazard.
\*
\* cache_updated_at is Atomic.t — readable without mutex.
\* cached_endpoints is a ref — MUST be read under cache_mu.
\*
\* Current code is correct: get_cached_or_refresh() takes mutex for both
\* TTL check and data read. But the Atomic guard invites a fast-path:
\*
\*   let quick_read () =
\*     if now - Atomic.get cache_updated_at < ttl then
\*       !cached_endpoints   (* BUG: ref read without mutex *)
\*     else get_cached_or_refresh ()
\*
\* This model proves that separating the TTL guard (Atomic) from the
\* data read (ref) allows torn reads during concurrent refresh.

EXTENDS Naturals

VARIABLES
    data_version,           \* Current ref value (writer increments)
    atomic_version,         \* Atomic TTL marker (writer updates after data)
    mutex_held_by,          \* "none" | "writer" | "reader"
    reader_atomic_snapshot, \* Atomic version the reader observed (0 = not read)
    reader_data_snapshot    \* Data version the reader got (0 = not read)

vars == <<data_version, atomic_version, mutex_held_by,
          reader_atomic_snapshot, reader_data_snapshot>>

TypeOK ==
    /\ data_version \in 1..10
    /\ atomic_version \in 0..10
    /\ mutex_held_by \in {"none", "writer", "reader"}
    /\ reader_atomic_snapshot \in 0..10
    /\ reader_data_snapshot \in 0..10

Init ==
    /\ data_version = 1
    /\ atomic_version = 1
    /\ mutex_held_by = "none"
    /\ reader_atomic_snapshot = 0
    /\ reader_data_snapshot = 0

\* ── Writer (refresh: update data then atomic) ───

\* Writer acquires mutex, updates data
WriterStart ==
    /\ mutex_held_by = "none"
    /\ data_version < 10
    /\ mutex_held_by' = "writer"
    /\ data_version' = data_version + 1
    /\ UNCHANGED <<atomic_version, reader_atomic_snapshot, reader_data_snapshot>>

\* Writer updates atomic and releases mutex
WriterFinish ==
    /\ mutex_held_by = "writer"
    /\ atomic_version' = data_version
    /\ mutex_held_by' = "none"
    /\ UNCHANGED <<data_version, reader_atomic_snapshot, reader_data_snapshot>>

\* ── Buggy Reader (fast-path: Atomic check then ref read, no mutex) ──

\* Reader checks Atomic without mutex
ReaderCheckAtomic ==
    /\ reader_data_snapshot = 0
    /\ reader_atomic_snapshot = 0
    /\ reader_atomic_snapshot' = atomic_version
    /\ UNCHANGED <<data_version, atomic_version, mutex_held_by, reader_data_snapshot>>

\* Reader reads ref without mutex (the bug)
ReaderReadNoMutex ==
    /\ reader_atomic_snapshot > 0
    /\ reader_data_snapshot = 0
    /\ reader_data_snapshot' = data_version
    /\ UNCHANGED <<data_version, atomic_version, mutex_held_by, reader_atomic_snapshot>>

\* Reader resets
ReaderReset ==
    /\ reader_data_snapshot > 0
    /\ reader_data_snapshot' = 0
    /\ reader_atomic_snapshot' = 0
    /\ UNCHANGED <<data_version, atomic_version, mutex_held_by>>

Next ==
    \/ WriterStart
    \/ WriterFinish
    \/ ReaderCheckAtomic
    \/ ReaderReadNoMutex
    \/ ReaderReset

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

\* ── Safety Invariant ────────────────────────────

\* When reader completes a read, the data it got must match the atomic
\* version it observed. A mismatch means torn read.
ConsistentRead ==
    (reader_data_snapshot > 0 /\ reader_atomic_snapshot > 0) =>
        reader_data_snapshot = reader_atomic_snapshot

\* ── Clean Model ─────────────────────────────────

\* Reader takes mutex, reads both atomic and data atomically.
ReaderMutexRead ==
    /\ reader_data_snapshot = 0
    /\ reader_atomic_snapshot = 0
    /\ mutex_held_by = "none"
    /\ mutex_held_by' = "reader"
    /\ reader_atomic_snapshot' = atomic_version
    /\ reader_data_snapshot' = data_version
    /\ UNCHANGED <<data_version, atomic_version>>

ReaderMutexRelease ==
    /\ mutex_held_by = "reader"
    /\ mutex_held_by' = "none"
    /\ UNCHANGED <<data_version, atomic_version, reader_atomic_snapshot, reader_data_snapshot>>

NextClean ==
    \/ WriterStart
    \/ WriterFinish
    \/ ReaderMutexRead
    \/ ReaderMutexRelease
    \/ ReaderReset

SpecClean == Init /\ [][NextClean]_vars /\ WF_vars(NextClean)
SpecBuggy == Init /\ [][Next]_vars /\ WF_vars(Next)

====
