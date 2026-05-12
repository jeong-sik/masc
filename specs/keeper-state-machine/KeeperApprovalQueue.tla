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
\*              approval requests. The two submit paths are represented
\*              by two separate optional fields on the entry, exactly one
\*              of which is populated:
\*                - [entry.resolver : ... Eio.Promise.u option]
\*                  — the [submit_and_await] case (Some r, on_resolution = None)
\*                - [entry.on_resolution : (approval_decision -> unit) option]
\*                  — the [submit_pending] case (resolver = None, on_resolution = Some f)
\*   resolver : Eio.Promise resolver tied to a fiber blocked on
\*              [Eio.Promise.await]. Resolving wakes the fiber.
\*
\* Scope (which path is modelled).  keeper_approval_queue.ml has two
\* submit entry points: [submit_and_await] (creates an [Eio.Promise],
\* registers the entry with [~resolver:(Some resolver)], then blocks the
\* caller on [Eio.Promise.await] — the entry has a SUSPENDED FIBER) and
\* [submit_pending] (registers with [~resolver:None] + an [on_resolution]
\* callback, returns the id immediately — NO suspended fiber; the
\* decision is delivered later via the callback).  This spec models the
\* [submit_and_await] variant — `suspended_fibers` counts those fibers.
\* The [submit_pending] variant has a different, weaker failure mode (a
\* dropped [on_resolution] callback, not a permanently blocked fiber);
\* it is out of scope here.  [expire_stale] handles BOTH via two
\* *syntactically* independent matches — `match entry.resolver with
\* Some r -> Eio.Promise.resolve r (Reject ...) | None -> ()` and,
\* separately, `match entry.on_resolution with Some f -> f (Reject ...)
\* | None -> ()`.  The two matches are *control-flow independent* —
\* neither references the other's field, so the choice on one side
\* doesn't constrain the other; the four (Some/None x Some/None)
\* combinations each have a defined branch (we do not promise clean
\* termination, only structural independence: `Eio.Promise.resolve` and
\* the `on_resolution` callback are unwrapped here and can still raise
\* `Eio.Cancel.Cancelled` etc., which the surrounding runtime re-raises
\* per its own policy).  Under the *current* runtime invariant exactly
\* one field is populated (submit_and_await sets resolver=Some,
\* on_resolution=None; submit_pending sets the reverse), so [resolver =
\* None] does imply [on_resolution = Some]; the independent-match shape
\* is defensive against a future refactor that might relax the producer
\* invariant.  The model abstracts only the effect on the
\* suspended-fiber population.
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
\* runtime, [expire_stale] *already* removes stale entries from
\* [pending] (via [atomic_update]) before it resolves/invokes anything,
\* capturing each removed [(id, entry)] in [stale_ref] precisely so it
\* can still call [Eio.Promise.resolve resolver (Reject ...)] (and
\* [entry.on_resolution]) afterwards.  The modelled hazard is therefore
\* NOT a reordering of removal vs resolve (removal is already first by
\* design) — it is a future refactor that loses or skips the captured
\* entry/resolver in that post-removal step (the [Some resolver] branch
\* dropped, [stale_ref] mis-built), leaving the entry gone from
\* [pending] with the resolve never run.  (NB: an [entry.resolver =
\* None] entry is a [submit_pending] request — it has NO suspended
\* fiber, so dropping it does not produce the modelled harm; its weaker
\* failure mode — a dropped [on_resolution] callback — is out of scope,
\* see the header.)
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
