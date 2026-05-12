---- MODULE KeeperApprovalQueue ----
\* Operator approval queue control flow for
\* [lib/keeper/keeper_approval_queue.ml].
\*
\* Runtime entities modelled (see functions [submit_and_await],
\* [submit_pending], [expire_stale]; iter 64 N-2.a removed line numbers
\* because OCaml line drift had reached +245..+413 from the original
\* cites — function names are stable, line numbers are not.  The drift
\* was audited in iter 63 #14919; iter 64 N-2.c adds a structural guard
\* at scripts/audit-tla-ml-line-refs.sh):
\*
\*   pending  : SMap from id to entry, holding submitted-but-unresolved
\*              approval requests. Each entry carries a resolver that
\*              wakes the suspended fiber.
\*   resolver : Eio.Promise resolver tied to a fiber blocked on
\*              [Eio.Promise.await]. Resolving wakes the fiber.
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
\* entry but forgets to call [Eio.Promise.resolve resolver]. The
\* fiber stays suspended forever. In the OCaml runtime this maps to
\* code paths where [entry.resolver] is None at expire time, or
\* where a future refactor moves the cleanup before the resolve.
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
