---- MODULE DashboardCacheClaim ----
\* Bug model: a Dashboard_cache compute queued behind the pool jobs that wait
\* for it (RFC-0204 3.4 L4b).
\*
\* Models lib/dashboard/dashboard_cache.ml:get_or_compute_eio for one key and
\* one Computing epoch. The owner is a request fiber outside the pool: it
\* installs Computing and submits its compute as pool job "O". Waiters are pool
\* jobs (an HTTP/1 outer compute) that look the key up while they hold a
\* worker. Pool jobs have weight 1.0: a worker runs one job at a time.
\*
\* Today a waiter that finds Computing polls while holding its worker. If every
\* worker is held that way and O is still queued, nothing runs until the
\* waiters time out (NoInversion).
\*
\* The fix: the Computing slot carries the owner's compute and a claim. Whoever
\* starts the compute first claims it: O when its job starts, or a waiter that
\* finds the compute not yet claimed, which runs it on the worker it holds. O's
\* job that loses the claim returns its worker at once and the owner waits for
\* the result outside the pool. Whoever claimed settles the result, Ok or
\* Failed, on every exit.
\*
\* Bug models (each replaces one clean action):
\*   NoClaim       waiters always poll (today's code)  -> NoInversion
\*   DoubleCompute O computes even when a waiter claimed -> AtMostOneRunner
\*   OrphanClaim   a claimant that fails leaves the claim unsettled
\*                                                     -> ClaimHasRunner, ClaimSettles

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Workers,    \* pool workers, e.g. {"w1"}
    Waiters     \* waiting pool jobs, e.g. {"h1", "h2"}

Owner == "O"
Jobs == {Owner} \cup Waiters
Idle == "idle"
NoClaim == "none"

VARIABLES
    queue,      \* pool FIFO of job ids
    worker,     \* [Workers -> Jobs \cup {Idle}]
    phase,      \* [Jobs -> phase]
    slot,       \* "absent" | "computing" | "ready"
    claim,      \* NoClaim | a job id: who runs the compute
    result,     \* "pending" | "ok" | "failed"
    owner       \* the owner fiber outside the pool

vars == <<queue, worker, phase, slot, claim, result, owner>>

Phases == {"init", "queued", "start", "lookup", "waiting", "computing", "done"}
OwnerStates == {"idle", "awaiting_job", "awaiting_result", "done", "failed", "cancelled"}

TypeOK ==
    /\ queue \in Seq(Jobs)
    /\ worker \in [Workers -> Jobs \cup {Idle}]
    /\ phase \in [Jobs -> Phases]
    /\ slot \in {"absent", "computing", "ready"}
    /\ claim \in Jobs \cup {NoClaim}
    /\ result \in {"pending", "ok", "failed"}
    /\ owner \in OwnerStates

Init ==
    /\ queue = <<>>
    /\ worker = [w \in Workers |-> Idle]
    /\ phase = [j \in Jobs |-> "init"]
    /\ slot = "absent"
    /\ claim = NoClaim
    /\ result = "pending"
    /\ owner = "idle"

HeldBy(j) == {w \in Workers : worker[w] = j}
Release(j) == worker' = [w \in Workers |-> IF worker[w] = j THEN Idle ELSE worker[w]]

\* ── Owner fiber (outside the pool) ─────────────────────────────

\* A miss installs Computing and submits the owner's compute as job O.
OwnerMiss ==
    /\ owner = "idle"
    /\ slot = "absent"
    /\ slot' = "computing"
    /\ owner' = "awaiting_job"
    /\ phase' = [phase EXCEPT ![Owner] = "queued"]
    /\ queue' = Append(queue, Owner)
    /\ UNCHANGED <<worker, claim, result>>

\* The owner whose job lost the claim reads the settled result.
OwnerReadsResult ==
    /\ owner = "awaiting_result"
    /\ result # "pending"
    /\ owner' = IF result = "ok" THEN "done" ELSE "failed"
    /\ UNCHANGED <<queue, worker, phase, slot, claim, result>>

\* The owner's deadline or client gives up: release_on_cancel removes the
\* Computing slot it installed (no stale value). A job already queued or
\* running goes on; it only publishes into a slot that is still Computing.
OwnerCancel ==
    /\ owner \in {"awaiting_job", "awaiting_result"}
    /\ owner' = "cancelled"
    /\ slot' = IF slot = "computing" THEN "absent" ELSE slot
    /\ UNCHANGED <<queue, worker, phase, claim, result>>

\* ── Pool ──────────────────────────────────────────────────────

WaiterSubmit(h) ==
    /\ phase[h] = "init"
    /\ phase' = [phase EXCEPT ![h] = "queued"]
    /\ queue' = Append(queue, h)
    /\ UNCHANGED <<worker, slot, claim, result, owner>>

Take(w) ==
    /\ worker[w] = Idle
    /\ queue # <<>>
    /\ LET j == Head(queue) IN
        /\ worker' = [worker EXCEPT ![w] = j]
        /\ phase' = [phase EXCEPT ![j] = IF j = Owner THEN "start" ELSE "lookup"]
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<slot, claim, result, owner>>

\* O's job starts: claim the compute, or hand the worker back at once.
OwnerJobStart ==
    /\ phase[Owner] = "start"
    /\ IF claim = NoClaim
       THEN /\ claim' = Owner
            /\ phase' = [phase EXCEPT ![Owner] = "computing"]
            /\ UNCHANGED <<worker, owner>>
       ELSE /\ phase' = [phase EXCEPT ![Owner] = "done"]
            /\ Release(Owner)
            /\ owner' = IF owner = "awaiting_job" THEN "awaiting_result" ELSE owner
            /\ UNCHANGED claim
    /\ UNCHANGED <<queue, slot, result>>

\* Bug: O's job computes whether or not a waiter already claimed.
OwnerJobStartDouble ==
    /\ phase[Owner] = "start"
    /\ claim' = IF claim = NoClaim THEN Owner ELSE claim
    /\ phase' = [phase EXCEPT ![Owner] = "computing"]
    /\ UNCHANGED <<queue, worker, slot, result, owner>>

\* A waiter looks the key up on the worker it holds.
WaiterLookup(h) ==
    /\ phase[h] = "lookup"
    /\ CASE slot = "computing" /\ claim = NoClaim ->
              /\ claim' = h
              /\ phase' = [phase EXCEPT ![h] = "computing"]
              /\ UNCHANGED worker
         [] slot = "computing" ->
              /\ phase' = [phase EXCEPT ![h] = "waiting"]
              /\ UNCHANGED <<worker, claim>>
         [] OTHER ->
              \* Hit, or a miss it handles as its own owner (out of model).
              /\ phase' = [phase EXCEPT ![h] = "done"]
              /\ Release(h)
              /\ UNCHANGED claim
    /\ UNCHANGED <<queue, slot, result, owner>>

\* Bug: today's code polls whether or not the compute has started.
WaiterLookupNoClaim(h) ==
    /\ phase[h] = "lookup"
    /\ IF slot = "computing"
       THEN /\ phase' = [phase EXCEPT ![h] = "waiting"]
            /\ UNCHANGED worker
       ELSE /\ phase' = [phase EXCEPT ![h] = "done"]
            /\ Release(h)
    /\ UNCHANGED <<queue, slot, claim, result, owner>>

\* A polling waiter sees the slot leave Computing.
WaiterWakes(h) ==
    /\ phase[h] = "waiting"
    /\ slot # "computing"
    /\ phase' = [phase EXCEPT ![h] = "done"]
    /\ Release(h)
    /\ UNCHANGED <<queue, slot, claim, result, owner>>

\* The running compute finishes. It publishes only into a Computing slot.
ComputeOk(j) ==
    /\ phase[j] = "computing"
    /\ slot' = IF slot = "computing" THEN "ready" ELSE slot
    /\ result' = IF claim = j THEN "ok" ELSE result
    /\ phase' = [phase EXCEPT ![j] = "done"]
    /\ Release(j)
    /\ owner' = IF j = Owner /\ owner = "awaiting_job" THEN "done" ELSE owner
    /\ UNCHANGED <<queue, claim>>

\* The running compute raises or is cancelled: settle Failed and clear the slot.
ComputeFails(j) ==
    /\ phase[j] = "computing"
    /\ slot' = IF slot = "computing" THEN "absent" ELSE slot
    /\ result' = IF claim = j THEN "failed" ELSE result
    /\ phase' = [phase EXCEPT ![j] = "done"]
    /\ Release(j)
    /\ owner' = IF j = Owner /\ owner = "awaiting_job" THEN "failed" ELSE owner
    /\ UNCHANGED <<queue, claim>>

\* Bug: a waiter that claimed and fails exits without settling or clearing.
ComputeFailsOrphan(j) ==
    /\ phase[j] = "computing"
    /\ IF j = Owner
       THEN /\ slot' = IF slot = "computing" THEN "absent" ELSE slot
            /\ result' = IF claim = j THEN "failed" ELSE result
            /\ owner' = IF owner = "awaiting_job" THEN "failed" ELSE owner
       ELSE UNCHANGED <<slot, result, owner>>
    /\ phase' = [phase EXCEPT ![j] = "done"]
    /\ Release(j)
    /\ UNCHANGED <<queue, claim>>

\* ── Specs ─────────────────────────────────────────────────────

Common ==
    \/ OwnerMiss \/ OwnerReadsResult \/ OwnerCancel
    \/ \E h \in Waiters : WaiterSubmit(h) \/ WaiterWakes(h)
    \/ \E w \in Workers : Take(w)

Next ==
    \/ Common
    \/ OwnerJobStart
    \/ \E h \in Waiters : WaiterLookup(h)
    \/ \E j \in Jobs : ComputeOk(j) \/ ComputeFails(j)

NextNoClaim ==
    \/ Common
    \/ OwnerJobStart
    \/ \E h \in Waiters : WaiterLookupNoClaim(h)
    \/ \E j \in Jobs : ComputeOk(j) \/ ComputeFails(j)

NextDouble ==
    \/ Common
    \/ OwnerJobStartDouble
    \/ \E h \in Waiters : WaiterLookup(h)
    \/ \E j \in Jobs : ComputeOk(j) \/ ComputeFails(j)

NextOrphan ==
    \/ Common
    \/ OwnerJobStart
    \/ \E h \in Waiters : WaiterLookup(h)
    \/ \E j \in Jobs : ComputeOk(j) \/ ComputeFailsOrphan(j)

\* A running compute ends, a started job acts, a free worker takes a job.
Fairness(N) ==
    /\ \A j \in Jobs : WF_vars(phase[j] = "computing" /\ N /\ phase'[j] = "done")
    /\ WF_vars(phase[Owner] = "start" /\ N /\ phase'[Owner] # "start")
    /\ \A w \in Workers : WF_vars(Take(w))
    /\ WF_vars(OwnerReadsResult)

Spec == Init /\ [][Next]_vars /\ Fairness(Next)
SpecNoClaim == Init /\ [][NextNoClaim]_vars /\ Fairness(NextNoClaim)
SpecDouble == Init /\ [][NextDouble]_vars /\ Fairness(NextDouble)
SpecOrphan == Init /\ [][NextOrphan]_vars /\ Fairness(NextOrphan)

\* ── Properties ────────────────────────────────────────────────

\* Never: O queued while every worker is held by a waiter polling for it.
NoInversion ==
    ~ ( /\ phase[Owner] = "queued"
        /\ \A w \in Workers : worker[w] \in Waiters /\ phase[worker[w]] = "waiting" )

\* The compute for this epoch runs at most once at a time.
AtMostOneRunner ==
    Cardinality({j \in Jobs : phase[j] = "computing"}) <= 1

\* A claim with no settled result has its claimant still running.
ClaimHasRunner ==
    (claim \in Jobs /\ result = "pending") => phase[claim] = "computing"

\* A claimed compute always ends Ok or Failed.
ClaimSettles == (claim # NoClaim) ~> (result # "pending")

====
