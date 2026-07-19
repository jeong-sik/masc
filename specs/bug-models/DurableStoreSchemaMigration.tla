---- MODULE DurableStoreSchemaMigration ----
\* Bug Model: durable store schema-version bump hard-cuts on-disk state.
\*
\* Models the boot-time load path shared by masc durable stores
\* (keeper_event_queue_persistence.ml, keeper_approval_queue.ml,
\*  keeper_checkpoint_store.ml, prompt_override_persistence.ml, ...).
\*
\* Buggy code (RFC-0344 §1): the binary is bumped to a new schema version, but
\*   the on-disk state is still the old version. The load path rejects the
\*   mismatch (Error / mark_store_unavailable) without migrating or preserving
\*   the old rows, so the durable data is orphaned while boot still proceeds.
\*   Observed 4x: #25078 (event queue), #25197 (reaction ledger), #25231
\*   (fusion codec), #25135 (gate pending: 367 HITL records orphaned).
\*
\* Fix (RFC-0344 §3.2): a boot preflight migrates old->current (no row lost),
\*   or fails loud leaving the data on disk for operator recovery. It never
\*   reports boot success while silently dropping durable rows.

EXTENDS Naturals

CONSTANT OldRows   \* durable rows present on disk before the version bump

VARIABLES
    disk_version,   \* "old" | "current"  (binary is at "current")
    live_rows,      \* rows readable by the running binary after boot
    on_disk_rows,   \* rows still physically present on disk
    boot_outcome    \* "pending" | "ok" | "fatal"

vars == <<disk_version, live_rows, on_disk_rows, boot_outcome>>

Init ==
    /\ disk_version = "old"      \* binary bumped to "current"; disk still "old"
    /\ live_rows = 0
    /\ on_disk_rows = OldRows
    /\ boot_outcome = "pending"

\* ── Safe boot preflight (RFC-0344 §3.2) ──────────────────────

\* Store provides a migration: old rows transformed to current, none lost.
PreflightMigrate ==
    /\ boot_outcome = "pending"
    /\ disk_version = "old"
    /\ disk_version' = "current"
    /\ live_rows' = OldRows          \* every row carried forward
    /\ on_disk_rows' = OldRows
    /\ boot_outcome' = "ok"

\* Store has no migration: fail loud, leave data on disk (operator recovers).
\* This is allowed — fail-loud is not data loss; the rows survive on disk.
PreflightFailLoud ==
    /\ boot_outcome = "pending"
    /\ disk_version = "old"
    /\ boot_outcome' = "fatal"
    /\ UNCHANGED <<disk_version, live_rows, on_disk_rows>>

\* Already current (fresh install or prior migration): load straight through.
PreflightUpToDate ==
    /\ boot_outcome = "pending"
    /\ disk_version = "current"
    /\ live_rows' = on_disk_rows
    /\ boot_outcome' = "ok"
    /\ UNCHANGED <<disk_version, on_disk_rows>>

Next == PreflightMigrate \/ PreflightFailLoud \/ PreflightUpToDate

\* ── Buggy boot (RFC-0344 §1: hard-cut reject) ────────────────

\* Failure mode A — drop-on-mismatch (keeper memory bank, §현황 위험 C):
\* boot is reported ok, the mismatched rows are rewritten out, and the durable
\* file no longer holds them.
HardCutAbsorb ==
    /\ boot_outcome = "pending"
    /\ disk_version = "old"
    /\ boot_outcome' = "ok"          \* boot reported successful ...
    /\ live_rows' = 0                \* ... yet no old row is readable ...
    /\ on_disk_rows' = 0             \* ... and the durable rows are gone.
    /\ disk_version' = "current"

\* Failure mode B — hard-cut reject / orphan (event queue #25078, gate #25135):
\* the load path rejects the old shape and marks the store Unavailable, so the
\* running binary reads nothing, yet the file is left intact on disk (orphaned).
\* Boot still proceeds ("ok") → silent outage. The file surviving on disk does
\* NOT satisfy the invariant: a boot reporting ok with no live rows is the bug,
\* whether or not the bytes are still on disk. This is the actually-observed
\* transition (read_primary_unlocked leaves the file, returns Unavailable).
HardCutOrphan ==
    /\ boot_outcome = "pending"
    /\ disk_version = "old"
    /\ boot_outcome' = "ok"          \* boot reported successful ...
    /\ live_rows' = 0                \* ... yet no old row is readable ...
    /\ on_disk_rows' = OldRows       \* ... though the file is left on disk.
    /\ disk_version' = "old"         \* store never advanced; it is Unavailable.

NextBuggy == Next \/ HardCutAbsorb \/ HardCutOrphan

\* ── Safety ───────────────────────────────────────────────────

\* If boot succeeded, every durable row present before the bump is accounted
\* for in live state. A "fatal" boot is exempt (fail-loud: data stays on disk).
\* A boot that reports "ok" while live_rows < OldRows is a silent durable loss.
NoDurableRowLostOnBump ==
    (boot_outcome = "ok") => (live_rows = OldRows)

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars
====
