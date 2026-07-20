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

\* Failure mode A — quarantine-on-bump (gate approval order, #25135 4190faacf1):
\* the loader renames the old-version file aside (`.v2.quarantine`) and starts
\* the store empty at the live path, so boot reports ok while the rows that were
\* readable before the bump are gone from the path the binary reads, and the
\* on-disk version at that path has advanced to current.
\*
\* NOTE (adversarial review, 2026-07-20): this action was previously attributed
\* to the keeper memory bank (§현황 위험 C). That citation was wrong — the
\* memory bank refuses compaction on mismatch before any write
\* (keeper_memory_bank.ml:567-582), so it never rewrites the file or advances
\* the on-disk version; its loss is read-side only and is covered by
\* HardCutOrphan's shape. #25135's quarantine is the real transition that
\* removes rows from the live path, so the action is retained under its actual
\* source rather than deleted.
\*
\* NOTE 2 (same review): quarantine uses Sys.rename
\* (keeper_approval_queue.ml:660-668), so the rows stay physically on disk at
\* the .vN.quarantine path — on_disk_rows must NOT drop to 0, which would
\* contradict this variable's definition and hide whether operator recovery is
\* still possible. What quarantine loses is the LIVE path, and that is already
\* what makes it a bug: boot reports ok with live_rows = 0. The distinction
\* from HardCutOrphan is disk_version: quarantine advances the live path to
\* current, orphan leaves it at old.
HardCutQuarantine ==
    /\ boot_outcome = "pending"
    /\ disk_version = "old"
    /\ boot_outcome' = "ok"          \* boot reported successful ...
    /\ live_rows' = 0                \* ... yet no old row is readable ...
    /\ on_disk_rows' = OldRows       \* ... though rename kept them at .vN.quarantine.
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

\* Each failure mode gets its own Next so it can be model-checked ALONE.
\* A single combined NextBuggy would still report "invariant violated" if one
\* of the two actions became unreachable or safe, because the other reaches the
\* violation from Init in one step — the expected-violation check would keep
\* passing while silently covering only one mode.
NextBuggyQuarantine == Next \/ HardCutQuarantine
NextBuggyOrphan == Next \/ HardCutOrphan

\* ── Safety ───────────────────────────────────────────────────

\* If boot succeeded, every durable row present before the bump is accounted
\* for in live state. A "fatal" boot is exempt (fail-loud: data stays on disk).
\* A boot that reports "ok" while live_rows < OldRows is a silent durable loss.
NoDurableRowLostOnBump ==
    (boot_outcome = "ok") => (live_rows = OldRows)

Spec == Init /\ [][Next]_vars
SpecBuggyQuarantine == Init /\ [][NextBuggyQuarantine]_vars
SpecBuggyOrphan == Init /\ [][NextBuggyOrphan]_vars
====
