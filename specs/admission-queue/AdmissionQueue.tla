---- MODULE AdmissionQueue ----
\* Phase 2-3 of the Kimi keeper FSM review plan.
\*
\* Mirrors the runtime [Admission_queue] (lib/admission_queue.ml).
\* The MASC-layer admission_queue is intentionally *passthrough* for
\* slot acquisition: provider-level throttling lives in OAS cascade,
\* not here. The MASC layer owns one host-resource guard
\* ([check_host_resources], fd >= 90% of fd_warn_threshold => reject)
\* plus metric collection (on_acquire / on_release) and cascade_name
\* canonicalisation at every entry point.
\*
\* This spec keeps the model honest: the dynamic state captured here
\* is exactly what main today enforces -- no priority queue, no
\* slot-bound waiter list, no backpressure. If MASC gains real
\* admission throttling later (cf. the original plan note "Hostage /
\* Backpressure spec") this module is the right place to grow it.
\*
\* OCaml <-> TLA+ mapping:
\*
\*   admission_state values
\*     "idle"          | global queue between requests; no decision in flight
\*     "checking"      | check_host_resources running for the current request
\*     "rejected_fd"   | fd >= 90% of threshold; admission denied
\*     "accepted"      | admission granted, work in flight (active>0)
\*
\*   variable                | OCaml site
\*   ------------------------+-----------------------------------------------------
\*   active                  | Admission_queue.global.active
\*   acquire_count           | Admission_queue_metrics.on_acquire calls
\*   release_count           | Admission_queue_metrics.on_release calls
\*   cascade_input           | raw cascade_name argument to with_permit
\*   cascade_recorded        | Keeper_cascade_profile.canonicalize cascade_input
\*   fd_count                | Prometheus.approximate_open_fd_count ()
\*
\* Out-of-scope (not in main today):
\*   - priority-sorted waiter list (the [waiter] / [insert_sorted] helpers
\*     exist as types but no acquire path enqueues into them today),
\*   - blocking semantics (Eio.Promise.create / await),
\*   - per-cascade quotas.
\* Adding any of those should land here as a new action set with a
\* matching invariant -- not a parallel spec.

EXTENDS TLC, Naturals

CONSTANTS
    FdThreshold,    \* Prometheus.fd_warn_threshold; small in the model
    FdGuardNum,     \* numerator of the guard fraction (OCaml = 9)
    FdGuardDen      \* denominator (OCaml = 10)

VARIABLES
    fd_count,
    admission_state,
    active,
    acquire_count,
    release_count,
    cascade_input,
    cascade_recorded

vars == << fd_count, admission_state, active, acquire_count,
            release_count, cascade_input, cascade_recorded >>

AdmissionStateSet == { "idle", "checking", "rejected_fd", "accepted" }

CascadeNameSet == { "raw_a", "raw_b", "canonical_a", "canonical_b", "" }

\* Mirror of [Keeper_cascade_profile.canonicalize]: the raw aliases
\* normalise to a single canonical form, canonical inputs and the
\* empty string are fixed points. Idempotent by construction.
Canonicalize(c) ==
    IF c = "raw_a" THEN "canonical_a"
    ELSE IF c = "raw_b" THEN "canonical_b"
    ELSE c

\* fd-count ceiling is bounded above the threshold so the model can
\* exercise both guard branches without unbounded state. The +1 lets
\* the buggy spec drive fd_count past the trigger.
FdMax == FdThreshold + 1

\* Boolean predicate matching the OCaml expression
\* [fd_count >= threshold * 9 / 10] (integer division). The
\* multiplication form avoids the rounding ambiguity that the OCaml
\* expression carries when threshold is small; the model uses the
\* >=-on-multiplied form so the bug-model can target the exact OCaml
\* branch without simulating C-style truncation.
GuardFires == fd_count * FdGuardDen >= FdGuardNum * FdThreshold

\* Concurrent-slot bound. Limits [active] (the running count of
\* in-flight work). Small enough to keep the state space manageable.
CounterMax == 6

\* Cumulative-counter bound. [acquire_count] and [release_count] are
\* monotonic and can grow without bound if the model runs long enough.
\* A separate, larger ceiling prevents TypeOK from clipping them while
\* still bounding the state space.
CumulativeMax == CounterMax * 2

TypeOK ==
    /\ fd_count \in 0..FdMax
    /\ admission_state \in AdmissionStateSet
    /\ active \in 0..CounterMax
    /\ acquire_count \in 0..CumulativeMax
    /\ release_count \in 0..CumulativeMax
    /\ cascade_input \in CascadeNameSet
    /\ cascade_recorded \in CascadeNameSet

Init ==
    /\ fd_count = 0
    /\ admission_state = "idle"
    /\ active = 0
    /\ acquire_count = 0
    /\ release_count = 0
    /\ cascade_input = ""
    /\ cascade_recorded = ""

\* The host's fd usage drifts independently of admission state. The
\* model lets it move only when no decision is in flight, which keeps
\* the state space small without losing coverage of the guard branch
\* (any fd value can be reached before SubmitRequest fires).
FdCountObserved(n) ==
    /\ admission_state = "idle"
    /\ n \in 0..FdMax
    /\ fd_count' = n
    /\ UNCHANGED << admission_state, active, acquire_count, release_count,
                    cascade_input, cascade_recorded >>

\* Operator submits an admission request with a raw cascade name. The
\* canonicalisation invariant lives in cascade_recorded' = Canonicalize.
\*
\* Modelling note: [acquire_count < CumulativeMax] is a model-only guard
\* added 2026-04-28 to avoid a TLC deadlock when both counters saturate
\* at CumulativeMax. In production [acquire_count] is unbounded, so the
\* situation never arises; the bound exists only to keep the model
\* state space finite. Without this guard, a state where
\* admission_state = "checking" and fd_count = 0 (so [GuardFires] is
\* false) and [acquire_count = CumulativeMax] (so [AcceptAndAcquire] is
\* disabled) and [release_count = acquire_count] (no Release to drain)
\* admits no enabled action -- TLC reports it as a deadlock. Disabling
\* SubmitRequest at counter saturation is the smallest model fix that
\* preserves the invariants we care about. PR #11582 attempted a
\* different fix path (cumulative-counter rebase); this one targets
\* the actual enabling-condition gap.
SubmitRequest(raw) ==
    /\ admission_state = "idle"
    /\ acquire_count < CumulativeMax
    /\ admission_state' = "checking"
    /\ cascade_input' = raw
    /\ cascade_recorded' = Canonicalize(raw)
    /\ UNCHANGED << fd_count, active, acquire_count, release_count >>

\* fd >= 90% of threshold ==> rejection. No counter movement.
RejectByFdGuard ==
    /\ admission_state = "checking"
    /\ GuardFires
    /\ admission_state' = "rejected_fd"
    /\ UNCHANGED << fd_count, active, acquire_count, release_count,
                    cascade_input, cascade_recorded >>

\* fd OK ==> acquire. Passthrough at MASC: no queue, just metric pair.
AcceptAndAcquire ==
    /\ admission_state = "checking"
    /\ ~ GuardFires
    /\ active < CounterMax
    /\ acquire_count < CumulativeMax
    /\ admission_state' = "accepted"
    /\ active' = active + 1
    /\ acquire_count' = acquire_count + 1
    /\ UNCHANGED << fd_count, release_count, cascade_input,
                    cascade_recorded >>

\* Work completes; on_release pairs with prior on_acquire.
Release ==
    /\ admission_state = "accepted"
    /\ active > 0
    /\ release_count < CumulativeMax
    /\ admission_state' = "idle"
    /\ active' = active - 1
    /\ release_count' = release_count + 1
    /\ UNCHANGED << fd_count, acquire_count, cascade_input,
                    cascade_recorded >>

\* Caller observed the rejection and returns to idle for the next
\* request without touching counters.
RejectionDrains ==
    /\ admission_state = "rejected_fd"
    /\ admission_state' = "idle"
    /\ UNCHANGED << fd_count, active, acquire_count, release_count,
                    cascade_input, cascade_recorded >>

Next ==
    \/ \E n \in 0..FdMax : FdCountObserved(n)
    \/ \E raw \in CascadeNameSet : SubmitRequest(raw)
    \/ RejectByFdGuard
    \/ AcceptAndAcquire
    \/ Release
    \/ RejectionDrains

Spec == Init /\ [][Next]_vars

\* ── Invariants ────────────────────────────────────────────────────────────

\* I1: FdThresholdEnforced. When admission resolves, the fd guard
\* branch determines the decision: rejected_fd <==> guard fired at
\* the moment of resolution. This is the OCaml site
\*   [if fd_count >= threshold * 9 / 10 then Error (...) else Ok ()].
FdThresholdEnforced ==
    /\ admission_state = "rejected_fd" => GuardFires
    /\ admission_state = "accepted"    => ~ GuardFires

\* I2: CascadeNameCanonical. Every recorded cascade_name equals the
\* canonical form of its input. Mirrors the OCaml SSOT comment at
\* admission_queue.ml line 140-142.
CascadeNameCanonical ==
    cascade_recorded = Canonicalize(cascade_input)

\* I3: ReleaseCountBounded. A release without a prior acquire would
\* be a spurious metric. release_count <= acquire_count is a strict
\* upper bound; eventual equality is captured by ActiveCounterConsistent
\* once the queue drains.
ReleaseCountBounded ==
    release_count <= acquire_count

\* I4: ActiveCounterConsistent. The running difference of acquire and
\* release matches the active counter exactly. Catches missed-release
\* leaks (a known concern: the OCaml [with_permit] body uses a [match
\* ... with exception exn ->] arm to release on failure; if that arm
\* is dropped during refactor the spec catches it as a counter drift).
ActiveCounterConsistent ==
    active = acquire_count - release_count

\* ── Bug actions (used only by SpecBuggy) ──────────────────────────────────

\* B1: FdGuardSkip. The OCaml branch
\*   [if fd_count >= threshold * 9 / 10 then Error _ else Ok ()]
\* is a structural bug class: a refactor that flips the comparison
\* (or drops the call site) admits requests above the fd warning
\* line. The bug model lets admission flip "checking" -> "accepted"
\* even when GuardFires.
FdGuardSkip ==
    /\ admission_state = "checking"
    /\ GuardFires
    /\ active < CounterMax
    /\ acquire_count < CumulativeMax
    /\ admission_state' = "accepted"
    /\ active' = active + 1
    /\ acquire_count' = acquire_count + 1
    /\ UNCHANGED << fd_count, release_count, cascade_input,
                    cascade_recorded >>

\* B2: ReleaseSkipped. The release-on-exception arm in [with_permit]
\* (lib/admission_queue.ml:158) is the load-bearing failure path for
\* counter health. The bug model drops the release while the work
\* finishes anyway, leaving active > 0 and acquire_count >
\* release_count permanently.
ReleaseSkipped ==
    /\ admission_state = "accepted"
    /\ admission_state' = "idle"
    /\ UNCHANGED << fd_count, active, acquire_count, release_count,
                    cascade_input, cascade_recorded >>

\* B3: CanonicalizeMissed. SSOT entry-point comment requires every
\* cascade_name to be canonicalised before record. The bug model lets
\* a caller skip the normalisation, recording the raw alias.
CanonicalizeMissed(raw) ==
    /\ admission_state = "idle"
    /\ admission_state' = "checking"
    /\ cascade_input' = raw
    /\ cascade_recorded' = raw            \* missed -- not Canonicalize(raw)
    /\ UNCHANGED << fd_count, active, acquire_count, release_count >>

NextBuggy ==
    \/ Next
    \/ FdGuardSkip
    \/ ReleaseSkipped
    \/ \E raw \in CascadeNameSet : CanonicalizeMissed(raw)

SpecBuggy == Init /\ [][NextBuggy]_vars

====
