---- MODULE KeeperApprovalQueue ----
\* Operator approval queue control flow for
\* [lib/keeper/keeper_approval_queue.ml].
\*
\* Runtime entities modelled (see functions [submit_and_await],
\* [submit_pending_blocking], [submit_pending_observer], [expire_stale];
\* iter 64 N-2.a removed line numbers
\* because OCaml line drift had reached +245..+413 from the original
\* cites — function names are stable, line numbers are not.  The drift
\* was audited in iter 63 #14919; iter 64 N-2.c adds a structural guard
\* at scripts/audit-tla-ml-line-refs.sh):
\*
\*   pending  : SMap from id to entry, holding submitted-but-unresolved
\*              approval requests. The three submit paths are represented
\*              by three separate optional fields on the entry, exactly one
\*              of which is populated by a public submission path:
\*                - [entry.resolver : ... Eio.Promise.u option]
\*                  — the [submit_and_await] blocking case
\*                - [entry.on_resolution_callback :
\*                     (approval_id -> approval_decision ->
\*                      blocking_resolution_plan) option]
\*                  — the [submit_pending_blocking] authoritative-plan case
\*                - [entry.on_resolution_observer :
\*                     (approval_decision -> unit) option]
\*                  — the [submit_pending_observer] non-authoritative case
\*   resolver : Eio.Promise resolver tied to a fiber blocked on
\*              [Eio.Promise.await]. Resolving wakes the fiber.
\*
\* Scope (which path is modelled). keeper_approval_queue.ml has three
\* submit entry points. [submit_and_await] creates an [Eio.Promise], registers
\* [resolver=Some], then blocks on [Eio.Promise.await].
\* [submit_pending_blocking] registers an authoritative plan builder. The
\* builder must be side-effect-free. The queue latches its typed decision,
\* invokes the plan's idempotent durable commit, removes the pending id,
\* publishes terminal audit, and only then runs the non-authoritative recovery
\* hint. Commit exception/cancellation leaves the latched entry pending for a
\* same-decision retry; a contradictory retry is rejected.
\* [submit_pending_observer] registers only a non-authoritative observer. Its
\* durable [Hitl_resolved] stimulus is the sole replayable decision carrier:
\* durable commit precedes pending removal, audit publication, observer, and
\* live signal. Observer failure is recorded but cannot restore, alter, or
\* retry the committed decision. Domain mutations therefore use the blocking
\* callback API until represented as a typed replayable effect.
\*
\* This count-only spec models only the [submit_and_await] variant;
\* `suspended_fibers` counts those fibers. It is not formal proof of blocking
\* callback decision latching, workspace isolation, callback/observer ordering,
\* or durable delivery. Focused OCaml tests own those contracts. Expiry is
\* processed per entry with the same lane-specific completion rules, so one
\* callback failure cannot discard its id or prevent a healthy neighbour from
\* expiring.
\*
\* The boundary critique flagged this as a black-box area: a tool call
\* submits an approval request and gets suspended on
\* [Eio.Promise.await]; if the operator UI disconnects without a
\* forced rejection path, the fiber stays blocked indefinitely. The
\* current OCaml code calls [Eio.Promise.resolve resolver (Reject
\* reason)] inside [expire_stale] which is correct,
\* but the safety property "every submitted approval is eventually
\* resolved or expired (and the fiber wakes)" was not enforced —
\* a future refactor could regress it silently.
\*
\* This spec turns that property into a model-checked invariant.
\* The clean Spec corresponds to today's OCaml behaviour.
\* SpecBuggy adds [ExpireStaleNoResolve] which models the regression:
\* the expire path drops the pending entry without resolving the
\* promise. The suspended fiber count then exceeds the pending count
\* (or, equivalently, a fiber stays suspended after the queue is
\* quiescent).
\*
\* Cycle 9 / Tier B3 of the Kimi keeper FSM review plan.
\*
\* Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec      under KeeperApprovalQueue.cfg       => TLC: no error.
\*   SpecBuggy under KeeperApprovalQueue-buggy.cfg => TLC: invariant
\*                                                   violated.
\* Both must hold.

EXTENDS Naturals

CONSTANTS
    MaxApprovals   \* state-space cap on total Submit invocations

ASSUME MaxApprovalsNat == MaxApprovals \in Nat /\ MaxApprovals >= 2

VARIABLES
    pending_count,        \* size of the pending SMap (submitted - resolved - expired)
    suspended_fibers,     \* fibers blocked on Eio.Promise.await
    submitted_total       \* monotone counter — bounded run cap

vars == << pending_count, suspended_fibers, submitted_total >>

TypeOK ==
    /\ pending_count    \in 0..MaxApprovals
    /\ suspended_fibers \in 0..MaxApprovals
    /\ submitted_total  \in 0..MaxApprovals

Init ==
    /\ pending_count    = 0
    /\ suspended_fibers = 0
    /\ submitted_total  = 0

\* ── Honest actions ─────────────────────────────────────────────

\* A keeper tool call submits an approval request; this both inserts
\* into the [pending] SMap and suspends the calling fiber on
\* [Eio.Promise.await].
Submit ==
    /\ submitted_total < MaxApprovals
    /\ pending_count'    = pending_count + 1
    /\ suspended_fibers' = suspended_fibers + 1
    /\ submitted_total'  = submitted_total + 1

\* The operator (or the rule engine) calls [Eio.Promise.resolve
\* resolver decision] which both wakes the suspended fiber and the
\* protect-finally cleanup removes the entry from [pending].
Resolve ==
    /\ pending_count > 0
    /\ pending_count'    = pending_count - 1
    /\ suspended_fibers' = suspended_fibers - 1
    /\ UNCHANGED submitted_total

\* [expire_stale] removes the pending entry AND resolves the promise
\* with [Reject "approval timed out after Ns"] in keeper_approval_queue.ml.
\* The fiber wakes up with a Reject decision.
ExpireStale ==
    /\ pending_count > 0
    /\ pending_count'    = pending_count - 1
    /\ suspended_fibers' = suspended_fibers - 1
    /\ UNCHANGED submitted_total

\* Stutter when the queue is fully reconciled.
Done ==
    /\ pending_count = 0
    /\ suspended_fibers = 0
    /\ UNCHANGED vars

\* ── Bug action (only in SpecBuggy) ─────────────────────────────

\* Models the regression where [expire_stale] removes the pending
\* entry of a [submit_and_await] request but never resolves its
\* promise — the suspended fiber stays blocked forever.  In the OCaml
\* runtime, [expire_stale] claims each stale id. A blocking promise entry is
\* removed immediately before [Eio.Promise.resolve] and restored if resolution
\* raises; a blocking callback entry is removed only after its authoritative
\* callback succeeds. A nonblocking entry commits durable delivery, is removed,
\* and only then runs its non-authoritative observer. The modelled hazard is a
\* future refactor that loses or skips the blocking resolver after removal.
\* (NB: [entry.resolver = None] is a
\* [submit_pending_observer] request with no suspended fiber; its durable-delivery
\* ordering is explicitly out of scope, see the header.)
ExpireStaleNoResolve ==
    /\ pending_count > 0
    /\ pending_count' = pending_count - 1
    /\ UNCHANGED << suspended_fibers, submitted_total >>

\* ── Spec wirings ───────────────────────────────────────────────

Next      == Submit \/ Resolve \/ ExpireStale \/ Done
NextBuggy == Next \/ ExpireStaleNoResolve

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariants ─────────────────────────────────────────

\* Core safety: every fiber that is suspended on Promise.await must
\* have a corresponding pending entry that holds its resolver. If
\* suspended_fibers > pending_count, some fiber is blocked with no
\* visible pending record — it cannot ever wake.
SuspensionMatchesPending ==
    suspended_fibers <= pending_count

\* Quiescent state: when nothing is pending, no fiber may be
\* suspended on Promise.await. The buggy ExpireStaleNoResolve action
\* drops the pending entry without resolving the promise; if the
\* queue then drains, a fiber is left suspended with no future
\* event capable of waking it.
QuiescentImpliesResolved ==
    (pending_count = 0) => (suspended_fibers = 0)

SafetyInvariant ==
    /\ SuspensionMatchesPending
    /\ QuiescentImpliesResolved

====
