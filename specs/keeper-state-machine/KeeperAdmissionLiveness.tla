---- MODULE KeeperAdmissionLiveness ----
\* Formal specification for RFC-0026 Work-Conserving Keeper Admission.
\* Models the admission gate that decides, for each keeper turn, whether
\* to dispatch on a provider, enqueue on the WFQ overflow queue, or
\* surface a capacity-exhausted event.
\*
\* This spec is the design ground for PR-A (#12904 keeper_provider_token_bucket)
\* and the planned PR-B/PR-C/PR-E series. It does NOT model:
\*   - in-attempt streaming liveness (RFC-0022)
\*   - cross-attempt watchdog (RFC-0012)
\*   - provider reputation aging (RFC-0009)
\* Those layers are orthogonal per RFC-0026 §1.
\*
\* OCaml <-> TLA+ mapping (target after PR-E):
\*   spec variable          | OCaml field / module                          | source
\*   -----------------------+-----------------------------------------------+--------
\*   keeper_state[k]        | (admission decision outcome)                  | lib/keeper/keeper_admission_router.ml
\*   token_bucket[p].tokens | bucket.tokens                                 | lib/keeper/keeper_provider_token_bucket.ml
\*   in_flight[p]           | bucket.in_flight                              | same
\*   wfq_queue              | overflow heap                                 | lib/keeper/keeper_wfq_overflow.ml
\*   wfq_deficit[k]         | per-entry deficit counter                     | same
\*
\* Liveness contract (RFC-0026 §3.1):
\*   I1 (LivenessInvariant)  : []<>(\A k. keeper_state[k] = "Dispatched")
\*   I2 (WorkConserving)     : never (waiting(k) /\ idle_compatible(p) for some p in candidates(k))
\*   I3 (RateRespect)        : in_flight[p] <= capacity[p]
\*   I4 (BoundedWait)        : enforced via WFQ fairness deviation bound (Shreedhar-Varghese)
\*   I5 (DriftObservable)    : every dispatch where preferred(k) /= actual(k) emits a log event
\*                             (modeled as last_dispatch[k] /= top_candidate(k))

EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Keepers,         \* Set of keeper identifiers, e.g. {"k1", "k2", "k3"}
    Providers,       \* Set of provider identifiers, e.g. {"anthropic", "glm", "ollama"}
    Candidates,      \* [Keepers -> Seq(Providers)]: ordered candidate list per keeper
    Capacity,        \* [Providers -> Nat]: max in_flight per provider
    InitialTokens,   \* [Providers -> Nat]: starting token count
    Weight           \* [Keepers -> Nat]: WFQ weight per keeper, default 1

ASSUME
    /\ Keepers # {}
    /\ Providers # {}
    /\ \A k \in Keepers : Len(Candidates[k]) > 0
    /\ \A k \in Keepers : Weight[k] >= 1
    /\ \A p \in Providers : Capacity[p] >= 1
    /\ \A p \in Providers : InitialTokens[p] <= Capacity[p]

VARIABLES
    keeper_state,    \* [Keepers -> {"Idle", "Waiting", "Dispatched", "Working", "Done"}]
    token_bucket,    \* [Providers -> Nat]: current available tokens
    in_flight,       \* [Providers -> Nat]: active dispatches
    wfq_queue,       \* Seq(Keepers): overflow queue, FIFO with deficit-weighted wake
    wfq_deficit,     \* [Keepers -> Nat]: deficit counter for WFQ fairness
    last_dispatch    \* [Keepers -> Providers \cup {"None"}]: provider used last turn

vars == <<keeper_state, token_bucket, in_flight, wfq_queue, wfq_deficit, last_dispatch>>

\* Helpers ───────────────────────────────────────────────────────────

\* CandidatesOf(k) returns the candidate sequence for keeper k as a set
\* (used when ordering does not matter for the predicate).
CandidatesOf(k) ==
    { Candidates[k][i] : i \in 1..Len(Candidates[k]) }

\* TopCandidate(k) is the preferred provider (head of Candidates[k]).
TopCandidate(k) == Candidates[k][1]

\* HasFreeToken(p) — admission gate non-blocking check.
HasFreeToken(p) == token_bucket[p] > 0 /\ in_flight[p] < Capacity[p]

\* AnyCandidateFree(k) — at least one of k's candidates has a free token.
\* Negation of this predicate is the precondition for entering the WFQ queue.
AnyCandidateFree(k) ==
    \E p \in CandidatesOf(k) : HasFreeToken(p)

\* QueueContains(k) — k is in the WFQ overflow queue.
QueueContains(k) == \E i \in 1..Len(wfq_queue) : wfq_queue[i] = k

\* InitialState ─────────────────────────────────────────────────────

Init ==
    /\ keeper_state = [k \in Keepers |-> "Idle"]
    /\ token_bucket = InitialTokens
    /\ in_flight = [p \in Providers |-> 0]
    /\ wfq_queue = <<>>
    /\ wfq_deficit = [k \in Keepers |-> 0]
    /\ last_dispatch = [k \in Keepers |-> "None"]

\* Actions ─────────────────────────────────────────────────────────

\* A1 — Keeper k starts a turn cycle.  Moves Idle -> Waiting and
\* immediately attempts admission on the next step (TryDispatch).
StartTurn(k) ==
    /\ keeper_state[k] = "Idle"
    /\ keeper_state' = [keeper_state EXCEPT ![k] = "Waiting"]
    /\ UNCHANGED <<token_bucket, in_flight, wfq_queue, wfq_deficit, last_dispatch>>

\* A2 — TryDispatch — for keeper k in Waiting, walk Candidates[k] in order.
\* If any candidate has a free token, atomically: consume token, increment
\* in_flight, set state = Dispatched, record last_dispatch.  This is the
\* non-blocking try_acquire path of RFC-0026 §3.2.
TryDispatch(k, p) ==
    /\ keeper_state[k] = "Waiting"
    /\ p \in CandidatesOf(k)
    /\ HasFreeToken(p)
    /\ keeper_state' = [keeper_state EXCEPT ![k] = "Dispatched"]
    /\ token_bucket' = [token_bucket EXCEPT ![p] = @ - 1]
    /\ in_flight' = [in_flight EXCEPT ![p] = @ + 1]
    /\ last_dispatch' = [last_dispatch EXCEPT ![k] = p]
    /\ UNCHANGED <<wfq_queue, wfq_deficit>>

\* A3 — EnqueueOverflow — keeper k is Waiting and NO candidate has a free
\* token.  Append to wfq_queue.  No mutation of token state.
EnqueueOverflow(k) ==
    /\ keeper_state[k] = "Waiting"
    /\ ~AnyCandidateFree(k)
    /\ ~QueueContains(k)
    /\ wfq_queue' = Append(wfq_queue, k)
    /\ UNCHANGED <<keeper_state, token_bucket, in_flight, wfq_deficit, last_dispatch>>

\* A4 — RefillToken(p) — provider p replenishes one token.  Modeled as a
\* discrete event; production refills at refill_rate_per_sec.
RefillToken(p) ==
    /\ token_bucket[p] < Capacity[p]
    /\ token_bucket' = [token_bucket EXCEPT ![p] = @ + 1]
    /\ UNCHANGED <<keeper_state, in_flight, wfq_queue, wfq_deficit, last_dispatch>>

\* A5 — WakeFromQueue — head of wfq_queue gets a wake-up attempt when
\* a token becomes available.  Choose the queue head (FIFO) for now;
\* PR-D-2 will refine to deficit-weighted selection.
WakeFromQueue ==
    /\ Len(wfq_queue) > 0
    /\ LET k == wfq_queue[1] IN
        /\ AnyCandidateFree(k)
        /\ wfq_queue' = Tail(wfq_queue)
        /\ wfq_deficit' = [wfq_deficit EXCEPT ![k] = @ + Weight[k]]
        /\ UNCHANGED <<keeper_state, token_bucket, in_flight, last_dispatch>>

\* A6 — StartWork(k) — Dispatched keeper begins LLM call.  Models the
\* transition into the in-attempt layer (RFC-0022 territory).
StartWork(k) ==
    /\ keeper_state[k] = "Dispatched"
    /\ keeper_state' = [keeper_state EXCEPT ![k] = "Working"]
    /\ UNCHANGED <<token_bucket, in_flight, wfq_queue, wfq_deficit, last_dispatch>>

\* A7 — CompleteWork(k) — keeper k finishes work, returns to Idle, and
\* releases its provider's slot.  Token is NOT refunded — capacity is
\* recovered via in_flight decrement.  Token is replenished separately
\* by RefillToken.
CompleteWork(k) ==
    /\ keeper_state[k] = "Working"
    /\ last_dispatch[k] # "None"
    /\ keeper_state' = [keeper_state EXCEPT ![k] = "Idle"]
    /\ in_flight' = [in_flight EXCEPT ![last_dispatch[k]] = @ - 1]
    /\ UNCHANGED <<token_bucket, wfq_queue, wfq_deficit, last_dispatch>>

\* Next step ─────────────────────────────────────────────────────────

Next ==
    \/ \E k \in Keepers : StartTurn(k)
    \/ \E k \in Keepers, p \in Providers : TryDispatch(k, p)
    \/ \E k \in Keepers : EnqueueOverflow(k)
    \/ \E p \in Providers : RefillToken(p)
    \/ WakeFromQueue
    \/ \E k \in Keepers : StartWork(k)
    \/ \E k \in Keepers : CompleteWork(k)

Spec == Init /\ [][Next]_vars

\* Safety invariants ─────────────────────────────────────────────────

\* I3 — RateRespect: in_flight per provider never exceeds capacity.
RateRespect ==
    \A p \in Providers : in_flight[p] <= Capacity[p]

\* TokensInRange — bucket count never goes negative or exceeds capacity.
TokensInRange ==
    \A p \in Providers : 0 <= token_bucket[p] /\ token_bucket[p] <= Capacity[p]

\* QueueWellFormed — each keeper at most once in the queue.
QueueWellFormed ==
    \A i, j \in 1..Len(wfq_queue) : i # j => wfq_queue[i] # wfq_queue[j]

\* TypeOK — basic type discipline.
TypeOK ==
    /\ keeper_state \in [Keepers -> {"Idle", "Waiting", "Dispatched", "Working", "Done"}]
    /\ token_bucket \in [Providers -> Nat]
    /\ in_flight \in [Providers -> Nat]
    /\ wfq_queue \in Seq(Keepers)
    /\ wfq_deficit \in [Keepers -> Nat]
    /\ last_dispatch \in [Keepers -> Providers \cup {"None"}]

\* I2 — WorkConserving: it is never the case that a keeper is Waiting
\* AND one of its candidates has a free token AND that keeper is not
\* in the WFQ queue (i.e. starvation by missed admission).
\*
\* The "is in the queue" exception captures fairness handover: a keeper
\* may be temporarily behind another in WFQ even when capacity exists,
\* but it MUST be on the queue (not silently sleeping).
WorkConserving ==
    \A k \in Keepers :
        (keeper_state[k] = "Waiting" /\ AnyCandidateFree(k))
            => keeper_state'[k] \in {"Dispatched", "Waiting"}
\* Note: this is a step-level safety predicate ("if you can dispatch,
\* either dispatch or yield to a waiting peer this step").  The full
\* I2 from RFC §3.1 is a temporal property (encoded under "Liveness"
\* below).

\* Liveness properties ───────────────────────────────────────────────

\* I1 — LivenessInvariant: every Idle keeper eventually becomes Dispatched
\* under the assumption that some candidate provider has positive long-run
\* refill rate.  In TLC we approximate via weak fairness on the actions
\* that move keepers forward.
\*
\* Fairness assumptions (model checked):
\*   - StartTurn is weakly fair for every keeper (heartbeat ticks).
\*   - RefillToken is weakly fair for every provider with capacity.
\*   - TryDispatch is weakly fair for every (keeper, candidate) pair.
\*   - WakeFromQueue is weakly fair when the queue is non-empty.
Fairness ==
    /\ \A k \in Keepers : WF_vars(StartTurn(k))
    /\ \A k \in Keepers : WF_vars(StartWork(k))
    /\ \A k \in Keepers : WF_vars(CompleteWork(k))
    /\ \A p \in Providers : WF_vars(RefillToken(p))
    /\ WF_vars(WakeFromQueue)
    /\ \A k \in Keepers, p \in Providers : WF_vars(TryDispatch(k, p))

LiveSpec == Spec /\ Fairness

\* I1 — every keeper is eventually dispatched infinitely often.
LivenessInvariant ==
    \A k \in Keepers : []<>(keeper_state[k] = "Dispatched")

\* Bounded-wait approximation: a Waiting keeper does not stay Waiting
\* forever (eventually transitions to Dispatched).
BoundedWait ==
    \A k \in Keepers :
        (keeper_state[k] = "Waiting") ~> (keeper_state[k] = "Dispatched")

\* Notes for next iteration (PR-D-2) ────────────────────────────────
\*
\* TODO 1: Add BugAction_GreedyKeeper that lets one keeper bypass
\*         EnqueueOverflow and re-enter Waiting in a tight loop.  Verify
\*         that LivenessInvariant fails under that bug.
\*
\* TODO 2: Add BugAction_LeakedToken that decrements token_bucket without
\*         incrementing in_flight (or vice versa).  Verify RateRespect
\*         fails.
\*
\* TODO 3: Refine WakeFromQueue to deficit-weighted: pick argmax_k
\*         (wfq_deficit[k] / Weight[k]) instead of FIFO head.  Mirrors
\*         Shreedhar-Varghese DRR.
\*
\* TODO 4: Model min_tier (RFC-0026 §3.3) by tagging each provider with
\*         a tier, and rejecting candidates below persona[k].min_tier.
\*         Verify that surface events still allow LivenessInvariant
\*         when at least one min_tier-acceptable provider exists.
\*
\* TODO 5: Two .cfg files:
\*         - KeeperAdmissionLiveness.cfg (clean, must satisfy I1+I2+I3)
\*         - KeeperAdmissionLiveness-buggy.cfg (Next \/ BugAction_*,
\*           must violate at least one invariant)
\*
\* TODO 6: Stuttering check — invariants must hold under stuttering
\*         (vars' = vars).  Default in TLA+; flag here for awareness.

====
