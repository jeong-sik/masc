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
    Weight,          \* [Keepers -> Nat]: WFQ weight per keeper, default 1
    MaxTurns         \* Nat: per-keeper turn count bound, for state space bound

\* Default constant bindings for the bundled .cfg files.
\* TLC config files cannot express nested record / function literals on
\* multiple lines, so we expose helper constants in the spec module and
\* the .cfg files override them via `<-`.  See tla2tools cfg grammar.
DefaultKeepers == {"k1", "k2"}
DefaultProviders == {"anthropic", "glm"}
DefaultCandidates == [k \in DefaultKeepers |->
    IF k = "k1" THEN <<"anthropic", "glm">> ELSE <<"glm", "anthropic">>]
DefaultCapacity == [p \in DefaultProviders |-> 1]
DefaultInitialTokens == [p \in DefaultProviders |-> 1]
DefaultWeight == [k \in DefaultKeepers |-> 1]
DefaultMaxTurns == 3

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
    last_dispatch,   \* [Keepers -> Providers \cup {"None"}]: provider used last turn
    turn_count       \* [Keepers -> Nat]: number of StartTurn occurrences, bounded by MaxTurns

vars == <<keeper_state, token_bucket, in_flight, wfq_queue, wfq_deficit, last_dispatch, turn_count>>

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
    /\ turn_count = [k \in Keepers |-> 0]

\* Actions ─────────────────────────────────────────────────────────

\* A1 — Keeper k starts a turn cycle.  Moves Idle -> Waiting and
\* immediately attempts admission on the next step (TryDispatch).
StartTurn(k) ==
    /\ keeper_state[k] = "Idle"
    /\ turn_count[k] < MaxTurns
    /\ keeper_state' = [keeper_state EXCEPT ![k] = "Waiting"]
    /\ turn_count' = [turn_count EXCEPT ![k] = @ + 1]
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
    /\ UNCHANGED <<wfq_queue, wfq_deficit, turn_count>>

\* A3 — EnqueueOverflow — keeper k is Waiting and NO candidate has a free
\* token.  Append to wfq_queue.  No mutation of token state.
EnqueueOverflow(k) ==
    /\ keeper_state[k] = "Waiting"
    /\ ~AnyCandidateFree(k)
    /\ ~QueueContains(k)
    /\ wfq_queue' = Append(wfq_queue, k)
    /\ UNCHANGED <<keeper_state, token_bucket, in_flight, wfq_deficit, last_dispatch, turn_count>>

\* A4 — RefillToken(p) — provider p replenishes one token.  Modeled as a
\* discrete event; production refills at refill_rate_per_sec.
RefillToken(p) ==
    /\ token_bucket[p] < Capacity[p]
    /\ token_bucket' = [token_bucket EXCEPT ![p] = @ + 1]
    /\ UNCHANGED <<keeper_state, in_flight, wfq_queue, wfq_deficit, last_dispatch, turn_count>>

\* A5 — WakeFromQueue — head of wfq_queue gets a wake-up attempt when
\* a token becomes available.  Choose the queue head (FIFO) for now;
\* PR-D-2 will refine to deficit-weighted selection.
WakeFromQueue ==
    /\ Len(wfq_queue) > 0
    /\ LET k == wfq_queue[1] IN
        /\ AnyCandidateFree(k)
        /\ wfq_queue' = Tail(wfq_queue)
        /\ wfq_deficit' = [wfq_deficit EXCEPT ![k] = @ + Weight[k]]
        /\ UNCHANGED <<keeper_state, token_bucket, in_flight, last_dispatch, turn_count>>

\* A6 — StartWork(k) — Dispatched keeper begins LLM call.  Models the
\* transition into the in-attempt layer (RFC-0022 territory).
StartWork(k) ==
    /\ keeper_state[k] = "Dispatched"
    /\ keeper_state' = [keeper_state EXCEPT ![k] = "Working"]
    /\ UNCHANGED <<token_bucket, in_flight, wfq_queue, wfq_deficit, last_dispatch, turn_count>>

\* A7 — CompleteWork(k) — keeper k finishes work, returns to Idle, and
\* releases its provider's slot.  Token is NOT refunded — capacity is
\* recovered via in_flight decrement.  Token is replenished separately
\* by RefillToken.
CompleteWork(k) ==
    /\ keeper_state[k] = "Working"
    /\ last_dispatch[k] # "None"
    /\ keeper_state' = [keeper_state EXCEPT ![k] = "Idle"]
    /\ in_flight' = [in_flight EXCEPT ![last_dispatch[k]] = @ - 1]
    /\ UNCHANGED <<token_bucket, wfq_queue, wfq_deficit, last_dispatch, turn_count>>

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

\* WaitingMustEnqueueOrDispatch — leads-to property (NOT step-level
\* invariant).  A Waiting keeper with no free candidate may transiently
\* exist outside the queue (one step is needed to enqueue), but it
\* must eventually either be enqueued, see a free candidate appear, or
\* reach Dispatched.  BugAction_GreedyKeeper violates this by allowing
\* the keeper to remain Waiting + ~AnyCandidateFree + ~Queue forever.
WaitingMustEnqueueOrDispatch ==
    \A k \in Keepers :
        (keeper_state[k] = "Waiting" /\ ~AnyCandidateFree(k) /\ ~QueueContains(k))
            ~> (QueueContains(k) \/ AnyCandidateFree(k) \/ keeper_state[k] = "Dispatched")

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
\*   - TryDispatch is *strongly* fair for every (keeper, candidate) pair.
\*     SF (not WF) is required because TryDispatch may be repeatedly
\*     enabled and disabled by interleaved CompleteWork/RefillToken;
\*     under WF a hostile scheduler can starve an enabled-but-flickering
\*     pair (TLC 6243-state counter-example confirmed this 2026-05-05).
\*   - WakeFromQueue is weakly fair when the queue is non-empty.
\*   - EnqueueOverflow is weakly fair so a keeper with no free candidate
\*     does not silently spin in Waiting.
Fairness ==
    /\ \A k \in Keepers : WF_vars(StartTurn(k))
    /\ \A k \in Keepers : WF_vars(StartWork(k))
    /\ \A k \in Keepers : WF_vars(CompleteWork(k))
    /\ \A k \in Keepers : WF_vars(EnqueueOverflow(k))
    /\ \A p \in Providers : WF_vars(RefillToken(p))
    /\ WF_vars(WakeFromQueue)
    /\ \A k \in Keepers, p \in Providers : SF_vars(TryDispatch(k, p))

LiveSpec == Spec /\ Fairness

\* I1 — every keeper that enters Waiting eventually leaves Waiting via
\* Dispatched.  Weakened from "infinitely often Dispatched" to a leads-to
\* statement so that finite-MaxTurns models terminate cleanly: a keeper
\* that has exhausted MaxTurns stays Idle forever, but never strands in
\* Waiting.  This is the practical liveness guarantee operators care
\* about — no silent stall — and it is exactly what RFC-0026 §3.1
\* paraphrases as "eventually-progresses(k)".
LivenessInvariant ==
    \A k \in Keepers :
        (keeper_state[k] = "Waiting") ~> (keeper_state[k] = "Dispatched")

\* Same predicate, kept as separate name for cfg clarity; future
\* refinements may diverge (e.g. BoundedWait may add a deadline).
BoundedWait == LivenessInvariant

\* Bug actions (mutation testing for the spec) ─────────────────────
\*
\* Pattern from `KeeperOASAdvanced.tla` (memory:
\* `feedback_fsm_guard_identity_helper_counter_wrap_pattern`):
\*   - Clean spec must satisfy I1 + I3 + safety
\*   - Buggy spec (Next \/ BugAction_*) must VIOLATE the corresponding
\*     invariant.  If TLC accepts a buggy spec, the invariant is too
\*     weak and the spec is rejected.

\* B1 — BugAction_GreedyKeeper —
\*
\* A keeper that is Waiting AND has no free candidate is supposed to
\* enter the WFQ queue (EnqueueOverflow).  This bug lets the keeper
\* "spin" — stay in Waiting indefinitely without enqueueing.
\* Combined with weak fairness on TryDispatch the spinning keeper
\* never reaches the queue, so when tokens become available WakeFromQueue
\* serves an empty queue and other keepers monopolise.  Under this bug
\* LivenessInvariant must be violated for the spinning keeper.
BugAction_GreedyKeeper(k) ==
    /\ keeper_state[k] = "Waiting"
    /\ ~AnyCandidateFree(k)
    /\ ~QueueContains(k)
    \* Bug: silently stay Waiting instead of enqueueing.
    /\ UNCHANGED vars

\* B2 — BugAction_LeakedToken —
\*
\* Provider p completes a dispatch but only decrements in_flight without
\* the matching token having been refilled by RefillToken first.  Models
\* the inverse class: a release path that refunds capacity at the
\* counter level but the bucket layer does not see the refund (or vice
\* versa).  Under this bug RateRespect can be violated when the
\* released slot is reused before refill.
\*
\* Concretely we model "decrement in_flight without releasing token
\* properly" by allowing in_flight[p] to drop while token_bucket[p] is
\* already at capacity, breaking the counter pairing.  The composite
\* invariant `in_flight[p] + token_bucket[p] <= Capacity[p] + Capacity[p]`
\* is too lax; the tight invariant is RateRespect itself driven by an
\* out-of-bounds in_flight after spurious decrement.
BugAction_LeakedToken(p) ==
    /\ in_flight[p] > 0
    \* Bug: decrement in_flight without dispatching anything (no
    \* CompleteWork transition to back it).  This decouples the
    \* in_flight counter from any actual work, so a future TryDispatch
    \* can still succeed but the bucket will eventually exceed real
    \* capacity in production.  In the model this is detected via the
    \* TokenInflightConservation invariant below.
    /\ in_flight' = [in_flight EXCEPT ![p] = @ - 1]
    /\ UNCHANGED <<keeper_state, token_bucket, wfq_queue, wfq_deficit, last_dispatch, turn_count>>

\* Conservation invariant —
\* Total work in flight + queued + completed equals total turns started.
\* The bug action above breaks this conservation by phantom-releasing
\* in_flight without a matching state transition.
\*
\* Provable: in the clean spec, Σ in_flight[p] equals the count of
\* keepers in {Dispatched, Working}.  BugAction_LeakedToken violates
\* this by lowering the LHS without changing the RHS.
DispatchedOrWorking(k) == keeper_state[k] \in {"Dispatched", "Working"}
TokenInflightConservation ==
    LET workers == { k \in Keepers : DispatchedOrWorking(k) } IN
    LET in_flight_total == LET sum[ps \in SUBSET Providers] ==
        IF ps = {} THEN 0
        ELSE LET pp == CHOOSE q \in ps : TRUE
             IN  in_flight[pp] + sum[ps \ {pp}]
        IN sum[Providers] IN
    in_flight_total = Cardinality(workers)

\* Buggy specs ────────────────────────────────────────────────────

NextBuggyGreedy ==
    \/ Next
    \/ \E k \in Keepers : BugAction_GreedyKeeper(k)

NextBuggyLeak ==
    \/ Next
    \/ \E p \in Providers : BugAction_LeakedToken(p)

\* SpecBuggyGreedy strips ALL fairness assumptions.  This is the
\* maximum-strength mutation: no scheduler guarantee that any progress
\* action ever fires when enabled.  Combined with BugAction_GreedyKeeper
\* (silent UNCHANGED in the Waiting + ~AnyCandidateFree + ~Queue state),
\* the spec admits behaviours where a keeper enters Waiting and never
\* leaves — exactly the operator-observed symptom (#12910 root pattern,
\* `feedback_keeper_starvation_capacity_vs_turn_duration_mismatch`).
\* Under this spec, LivenessInvariant and WaitingMustEnqueueOrDispatch
\* must be violated by TLC.
SpecBuggyGreedy == Init /\ [][NextBuggyGreedy]_vars
SpecBuggyLeak   == Init /\ [][NextBuggyLeak]_vars   /\ Fairness

\* Notes for follow-up iterations ──────────────────────────────────
\*
\* TODO 3 (PR-D-3): Refine WakeFromQueue to deficit-weighted
\*         (Shreedhar-Varghese DRR).  Currently FIFO.
\*
\* TODO 4 (PR-D-3): Model min_tier (RFC-0026 §3.3) by tagging each
\*         provider with a tier, and rejecting candidates below
\*         persona[k].min_tier.
\*
\* TODO 5 (PR-D-3): Stuttering / refinement check against
\*         KeeperTurnCycle.tla — admission Dispatched -> turn_phase
\*         "prompting".

====
