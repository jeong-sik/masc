---- MODULE AtomicFileWrite ----
\* Bug Model: Non-atomic file write race condition.
\*
\* Models masc_grpc_service.ml heartbeat write.
\* Old code: Fs_compat.save_file (truncate-then-write) allows concurrent
\* reader to see empty file between truncate and write completion.
\* Fix: tmp file + rename (atomic on POSIX).

EXTENDS Naturals

VARIABLES
    file_state,     \* "absent" | "valid" | "truncated" | "writing"
    tmp_state,      \* "absent" | "valid"
    reader_result,  \* "none" | "valid" | "empty" | "partial"
    writer_phase,   \* "idle" | "truncating" | "writing" | "renaming" | "done"
    reader_phase    \* "idle" | "reading" | "done"

vars == <<file_state, tmp_state, reader_result, writer_phase, reader_phase>>

Init ==
    /\ file_state = "valid"    \* File starts with valid content
    /\ tmp_state = "absent"
    /\ reader_result = "none"
    /\ writer_phase = "idle"
    /\ reader_phase = "idle"

\* ── Unsafe Writer (truncate-then-write) ────────────────

UnsafeTruncate ==
    /\ writer_phase = "idle"
    /\ writer_phase' = "truncating"
    /\ file_state' = "truncated"   \* File is now empty
    /\ UNCHANGED <<tmp_state, reader_result, reader_phase>>

UnsafeWrite ==
    /\ writer_phase = "truncating"
    /\ writer_phase' = "done"
    /\ file_state' = "valid"       \* Content written
    /\ UNCHANGED <<tmp_state, reader_result, reader_phase>>

\* ── Safe Writer (tmp + rename) ─────────────────────────

SafeWriteTmp ==
    /\ writer_phase = "idle"
    /\ writer_phase' = "writing"
    /\ tmp_state' = "valid"        \* Write to tmp file
    /\ UNCHANGED <<file_state, reader_result, reader_phase>>

SafeRename ==
    /\ writer_phase = "writing"
    /\ writer_phase' = "done"
    /\ file_state' = "valid"       \* Atomic rename
    /\ tmp_state' = "absent"       \* Tmp consumed
    /\ UNCHANGED <<reader_result, reader_phase>>

\* ── Reader (can interleave with writer) ────────────────

Read ==
    /\ reader_phase = "idle"
    /\ reader_phase' = "done"
    /\ reader_result' = CASE file_state = "valid"     -> "valid"
                          [] file_state = "truncated"  -> "empty"
                          [] file_state = "absent"     -> "empty"
                          [] OTHER                     -> "partial"
    /\ UNCHANGED <<file_state, tmp_state, writer_phase>>

\* ── Unsafe Next (bug model) ───────────────────────────

NextBuggy ==
    \/ UnsafeTruncate
    \/ UnsafeWrite
    \/ Read

SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safe Next (fixed model) ───────────────────────────

NextSafe ==
    \/ SafeWriteTmp
    \/ SafeRename
    \/ Read

SpecSafe == Init /\ [][NextSafe]_vars

\* ── Safety Invariant ──────────────────────────────────

\* Reader must NEVER see an empty file.
ReaderNeverSeesEmpty ==
    reader_result # "empty"

====
