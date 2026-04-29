---- MODULE AuditLog ----
\* Boundary spec for the audit_log cache install path
\* (lib/audit_log.ml:202-213).
\*
\* Source declares the cache-mutex invariant in comments
\* (lib/audit_log.ml:193-201):
\*
\*     The cache itself is protected by [audit_store_cache_mu] so that
\*     two concurrent [get_audit_store] calls for the same base dir
\*     cannot install two [Dated_jsonl.t] records with different inner
\*     [Eio.Mutex] instances -- otherwise file I/O to the same
\*     [YYYY-MM/DD.jsonl] path would serialise through two different
\*     mutexes and racing appends could interleave on disk.
\*
\* This spec encodes that single safety claim in finite state: under
\* the mutex the read-or-create-then-install sequence is atomic, so
\* exactly one Dated_jsonl instance is ever installed per base_dir.
\* The buggy variant strips the mutex so two fibers can both observe
\* an empty cache and both install distinct instances, violating
\* CacheConsistency.
\*
\* Scope is intentionally narrow: only the cache-install race is
\* modelled.  Append-ordering and durability live downstream of
\* Dated_jsonl and warrant their own specs (#11655 Phase 2 / 3
\* candidates).
\*
\* Bug Model (memory: TLA+ Bug Model pattern):
\*   Spec       (clean): Atomic probe-and-install -- install_count <= 1.
\*   SpecBuggy:
\*       ProbeBug + InstallBug -- non-atomic probe and install can
\*       run interleaved across fibers, so two empty-probe winners
\*       both install -> install_count >= 2 -> CacheConsistency
\*       violated.
\*
\* Reference: issue #11655 (follow-up of #11522 Phase 4 MED2).
\* Memory: feedback_TLA-Bug-Model-pattern.

EXTENDS TLC, Naturals, FiniteSets

CONSTANTS Fibers   \* set of concurrent fibers, e.g. {1, 2}

NoStore == 0

VARIABLES
    cache,           \* installed Dated_jsonl instance id, 0 = empty
    next_id,         \* monotonic id supply (next instance to install)
    install_count,   \* total writes to cache (clean: at most 1)
    pc               \* per-fiber program counter

vars == <<cache, next_id, install_count, pc>>

\* The clean model only needs Idle / Done; Probed is reserved for the
\* buggy model below.
PCStates == {"Idle", "Probed", "Done"}

\* Bound state space for TLC.  install_count above 2 is meaningful
\* only for the buggy spec; bounding it slightly above the violation
\* threshold keeps clean runs well within range.
MaxInstalls == Cardinality(Fibers)

TypeOK ==
    /\ cache \in 0..MaxInstalls
    /\ next_id \in 1..(MaxInstalls + 1)
    /\ install_count \in 0..MaxInstalls
    /\ pc \in [Fibers -> PCStates]

Init ==
    /\ cache = NoStore
    /\ next_id = 1
    /\ install_count = 0
    /\ pc = [f \in Fibers |-> "Idle"]

\* Clean: probe-and-install is atomic under audit_store_cache_mu.
\* Either cache hit (no install) or cache miss + install in one step.
\* Mirrors [Eio_guard.with_mutex audit_store_cache_mu (fun () ->
\*   match StringMap.find_opt base !audit_store_cache with ...)].
ProbeAndInstallAtomic(f) ==
    /\ pc[f] = "Idle"
    /\ IF cache # NoStore
       THEN /\ pc' = [pc EXCEPT ![f] = "Done"]
            /\ UNCHANGED <<cache, next_id, install_count>>
       ELSE /\ cache' = next_id
            /\ next_id' = next_id + 1
            /\ install_count' = install_count + 1
            /\ pc' = [pc EXCEPT ![f] = "Done"]

Next ==
    \E f \in Fibers : ProbeAndInstallAtomic(f)

Spec == Init /\ [][Next]_vars

\* ── Invariants ──────────────────────────────────────────────────

\* CacheConsistency (the source-declared invariant): across the
\* whole run, at most one Dated_jsonl instance is ever installed
\* for the single base_dir modelled here.  Direct encoding of
\* "two concurrent get_audit_store calls cannot install two
\* Dated_jsonl.t records with different inner Eio.Mutex instances".
CacheConsistency ==
    install_count <= 1

\* ── Bug actions (used only by SpecBuggy) ────────────────────────

\* B1 ProbeBug.  Refactor strips the mutex around the read path.
\* A fiber observes an empty cache without holding the mutex, so a
\* sibling fiber can also observe empty before either installs.
ProbeBug(f) ==
    /\ pc[f] = "Idle"
    /\ cache = NoStore   \* race window: empty observed without mutex
    /\ pc' = [pc EXCEPT ![f] = "Probed"]
    /\ UNCHANGED <<cache, next_id, install_count>>

\* B2 InstallBug.  The same refactor moves the install outside the
\* mutex.  A fiber that earlier saw NoStore now writes the cache
\* unconditionally, even if another fiber has already installed --
\* second install ratchets install_count past 1.
InstallBug(f) ==
    /\ pc[f] = "Probed"
    /\ cache' = next_id
    /\ next_id' = next_id + 1
    /\ install_count' = install_count + 1
    /\ pc' = [pc EXCEPT ![f] = "Done"]

NextBuggy ==
    \/ Next
    \/ \E f \in Fibers : ProbeBug(f)
    \/ \E f \in Fibers : InstallBug(f)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
