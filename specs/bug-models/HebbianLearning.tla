---- MODULE HebbianLearning ----
\* Bug Model: Hebbian read-modify-write without file lock.
\*
\* Models hebbian_eio.ml strengthen/consolidate concurrency.
\* Each operation does: load → compute → save. The file lock
\* serializes these so no interleaving writes occur between
\* an operation's load and save.
\*
\* Without the lock, operation A can save between B's load and save,
\* causing B to clobber A's effect (lost update).
\*
\* Invariant: when an operation saves, no other write has happened
\* since that operation loaded (graph_version == load_version + 1).
\*
\* Reference (verified 2026-04-20):
\*   lib/hebbian_eio.ml:strengthen — wraps body in with_graph_lock config
\*     (load -> compute -> save).
\*   The lock-required pattern is enforced by call-site convention
\*   (every public mutator calls with_graph_lock); there is no inline
\*   docstring inside the strengthen body.

EXTENDS Naturals

CONSTANTS
    MaxWeight,         \* Upper bound (default 10)
    StrengthenRate,    \* Increment per strengthen (default 1)
    DecayAmount,       \* Decrement per consolidate (default 1)
    MaxVersion         \* State constraint bound on graph_version to keep TLC finite

VARIABLES
    graph_weight,       \* Current on-disk weight
    graph_version,      \* Monotonic counter, incremented on each save
    lock,               \* "free" | "strengthen" | "consolidate"
    str_phase,          \* "idle" | "loaded" | "computed" | "saved"
    str_snapshot,       \* Weight that strengthen loaded
    str_load_ver,       \* graph_version when strengthen loaded
    str_save_ver,       \* graph_version after strengthen saved (0 if never)
    con_phase,          \* "idle" | "loaded" | "computed" | "saved"
    con_snapshot,       \* Weight that consolidate loaded
    con_load_ver,       \* graph_version when consolidate loaded
    con_save_ver        \* graph_version after consolidate saved (0 if never)

vars == <<graph_weight, graph_version, lock,
          str_phase, str_snapshot, str_load_ver, str_save_ver,
          con_phase, con_snapshot, con_load_ver, con_save_ver>>

Init ==
    /\ graph_weight = 5
    /\ graph_version = 0
    /\ lock = "free"
    /\ str_phase = "idle"
    /\ str_snapshot = 0
    /\ str_load_ver = 0
    /\ str_save_ver = 0
    /\ con_phase = "idle"
    /\ con_snapshot = 0
    /\ con_load_ver = 0
    /\ con_save_ver = 0

\* ── Safe (locked) strengthen ──────────────────────────

SafeStrAcquire ==
    /\ str_phase = "idle"
    /\ lock = "free"
    /\ lock' = "strengthen"
    /\ str_phase' = "loaded"
    /\ str_snapshot' = graph_weight
    /\ str_load_ver' = graph_version
    /\ UNCHANGED <<graph_weight, graph_version, str_save_ver,
                   con_phase, con_snapshot, con_load_ver, con_save_ver>>

SafeStrCompute ==
    /\ str_phase = "loaded"
    /\ str_phase' = "computed"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_snapshot, str_load_ver, str_save_ver,
                   con_phase, con_snapshot, con_load_ver, con_save_ver>>

SafeStrSave ==
    /\ str_phase = "computed"
    /\ graph_weight' = IF str_snapshot + StrengthenRate > MaxWeight
                       THEN MaxWeight
                       ELSE str_snapshot + StrengthenRate
    /\ graph_version' = graph_version + 1
    /\ str_save_ver' = graph_version + 1
    /\ str_phase' = "saved"
    /\ lock' = "free"
    /\ UNCHANGED <<str_snapshot, str_load_ver, con_phase, con_snapshot, con_load_ver, con_save_ver>>

SafeStrReset ==
    /\ str_phase = "saved"
    /\ str_phase' = "idle"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_snapshot, str_load_ver, str_save_ver,
                   con_phase, con_snapshot, con_load_ver, con_save_ver>>

\* ── Safe (locked) consolidate ─────────────────────────

SafeConAcquire ==
    /\ con_phase = "idle"
    /\ lock = "free"
    /\ lock' = "consolidate"
    /\ con_phase' = "loaded"
    /\ con_snapshot' = graph_weight
    /\ con_load_ver' = graph_version
    /\ UNCHANGED <<graph_weight, graph_version, str_phase, str_snapshot, str_load_ver, str_save_ver, con_save_ver>>

SafeConCompute ==
    /\ con_phase = "loaded"
    /\ con_phase' = "computed"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_phase, str_snapshot, str_load_ver, str_save_ver,
                   con_snapshot, con_load_ver, con_save_ver>>

SafeConSave ==
    /\ con_phase = "computed"
    /\ graph_weight' = IF con_snapshot < DecayAmount THEN 0
                       ELSE con_snapshot - DecayAmount
    /\ graph_version' = graph_version + 1
    /\ con_save_ver' = graph_version + 1
    /\ con_phase' = "saved"
    /\ lock' = "free"
    /\ UNCHANGED <<str_phase, str_snapshot, str_load_ver, str_save_ver, con_snapshot, con_load_ver>>

SafeConReset ==
    /\ con_phase = "saved"
    /\ con_phase' = "idle"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_phase, str_snapshot, str_load_ver, str_save_ver,
                   con_snapshot, con_load_ver, con_save_ver>>

\* ── Unsafe (no lock) strengthen ───────────────────────

UnsafeStrLoad ==
    /\ str_phase = "idle"
    /\ str_phase' = "loaded"
    /\ str_snapshot' = graph_weight
    /\ str_load_ver' = graph_version
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_save_ver,
                   con_phase, con_snapshot, con_load_ver, con_save_ver>>

UnsafeStrCompute ==
    /\ str_phase = "loaded"
    /\ str_phase' = "computed"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_snapshot, str_load_ver, str_save_ver,
                   con_phase, con_snapshot, con_load_ver, con_save_ver>>

UnsafeStrSave ==
    /\ str_phase = "computed"
    /\ graph_weight' = IF str_snapshot + StrengthenRate > MaxWeight
                       THEN MaxWeight
                       ELSE str_snapshot + StrengthenRate
    /\ graph_version' = graph_version + 1
    /\ str_save_ver' = graph_version + 1
    /\ str_phase' = "saved"
    /\ UNCHANGED <<lock, str_snapshot, str_load_ver,
                   con_phase, con_snapshot, con_load_ver, con_save_ver>>

UnsafeStrReset ==
    /\ str_phase = "saved"
    /\ str_phase' = "idle"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_snapshot, str_load_ver, str_save_ver,
                   con_phase, con_snapshot, con_load_ver, con_save_ver>>

\* ── Unsafe (no lock) consolidate ──────────────────────

UnsafeConLoad ==
    /\ con_phase = "idle"
    /\ con_phase' = "loaded"
    /\ con_snapshot' = graph_weight
    /\ con_load_ver' = graph_version
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_phase, str_snapshot, str_load_ver, str_save_ver, con_save_ver>>

UnsafeConCompute ==
    /\ con_phase = "loaded"
    /\ con_phase' = "computed"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_phase, str_snapshot, str_load_ver, str_save_ver,
                   con_snapshot, con_load_ver, con_save_ver>>

UnsafeConSave ==
    /\ con_phase = "computed"
    /\ graph_weight' = IF con_snapshot < DecayAmount THEN 0
                       ELSE con_snapshot - DecayAmount
    /\ graph_version' = graph_version + 1
    /\ con_save_ver' = graph_version + 1
    /\ con_phase' = "saved"
    /\ UNCHANGED <<lock, str_phase, str_snapshot, str_load_ver, str_save_ver, con_snapshot, con_load_ver>>

UnsafeConReset ==
    /\ con_phase = "saved"
    /\ con_phase' = "idle"
    /\ UNCHANGED <<graph_weight, graph_version, lock, str_phase, str_snapshot, str_load_ver, str_save_ver,
                   con_snapshot, con_load_ver, con_save_ver>>

\* ── Specifications ────────────────────────────────────

NextSafe ==
    \/ SafeStrAcquire \/ SafeStrCompute \/ SafeStrSave \/ SafeStrReset
    \/ SafeConAcquire \/ SafeConCompute \/ SafeConSave \/ SafeConReset

NextBuggy ==
    \/ UnsafeStrLoad \/ UnsafeStrCompute \/ UnsafeStrSave \/ UnsafeStrReset
    \/ UnsafeConLoad \/ UnsafeConCompute \/ UnsafeConSave \/ UnsafeConReset

Spec == Init /\ [][NextSafe]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety Invariants ─────────────────────────────────

\* Weight is always bounded.
WeightBounded == graph_weight >= 0 /\ graph_weight <= MaxWeight

\* No lost update: when an operation saves, no other write has
\* occurred since that operation loaded.  We capture each save's
\* version at save-time (str_save_ver / con_save_ver) and check
\* that save_ver = load_ver + 1, meaning this save was immediately
\* after the load with no intervening writes.
\*
\* Safe model: lock guarantees exclusive load-compute-save, so
\*   save_ver = load_ver + 1 always.
\* Buggy model: another operation can save between load and save,
\*   making save_ver > load_ver + 1 (violation).
NoLostUpdate ==
    /\ (str_phase = "saved" => str_save_ver = str_load_ver + 1)
    /\ (con_phase = "saved" => con_save_ver = con_load_ver + 1)

\* State constraint: keep TLC finite by bounding graph_version.
\* This is NOT a safety property; it truncates exploration.
VersionBound == graph_version <= MaxVersion

====
