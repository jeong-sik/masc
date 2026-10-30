---- MODULE DashboardCacheClaim ----
\* Bug model: a Dashboard_cache compute queued behind the pool jobs that wait
\* for it (RFC-0204 3.4 L4b).
\*
\* Models lib/dashboard/dashboard_cache.ml:get_or_compute_eio for one key and
\* one Computing epoch (own_claimed, run_claimed, the `Wait claim guard).
\* The owner is a fiber outside the pool: it installs Computing with an
\* unclaimed claim and submits its compute as pool job "O". Waiters are pool
\* jobs (an HTTP/1 outer compute) that look the key up while they hold a
\* worker. Pool jobs have weight 1.0: a worker runs one job at a time.
\*
\* Today a waiter that finds Computing polls while holding its worker. If every
\* worker is held that way and O is still queued, nothing runs until the
\* waiters time out (NoInversion).
\*
\* The fix: whoever starts the compute first claims it, O when its job starts
\* or a waiter that finds it unclaimed (a separate step after the lookup, as in
\* the code). Whoever runs it publishes, settles the outcome and, on failure
\* or release, clears the slot. The owner returns as soon as the outcome is
\* settled, which cancels O if it is still queued; a Released outcome sends it
\* back to look the key up (a new epoch, out of model). An owner that gives up
\* abandons an unclaimed compute and clears the slot, and leaves a claimed one
\* to its runner.
\*
\* Bug models (each replaces one clean action):
\*   NoClaim          waiters always poll (the code before L4b) -> NoInversion
\*   IgnoreClaim      O computes even after a waiter claimed     -> AtMostOneRunner
\*   OrphanClaim      a failing claimant neither settles nor clears
\*                                                -> ClaimHasRunner, ClaimSettles
\*   OwnerClearsClaim an owner that gives up clears a claimed slot
\*                                                -> ClaimantKeepsSlot

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Workers,    \* pool workers, e.g. {"w1"}
    Waiters     \* waiting pool jobs, e.g. {"h1", "h2"}

Owner == "O"
Jobs == {Owner} \cup Waiters
Idle == "idle"
Unclaimed == "unclaimed"
Abandoned == "abandoned"

VARIABLES
    queue,      \* pool FIFO of job ids
    worker,     \* [Workers -> Jobs \cup {Idle}]
    phase,      \* [Jobs -> phase]
    slot,       \* "absent" | "computing" | "ready"
    holder,     \* Unclaimed | Abandoned | the job that runs the compute
    result,     \* "pending" | "ok" | "failed" | "released"
    owner       \* the owner fiber outside the pool

vars == <<queue, worker, phase, slot, holder, result, owner>>

Phases == {"init", "queued", "start", "lookup", "claiming", "waiting",
           "computing", "done", "cancelled"}
OwnerStates == {"idle", "waiting", "done", "failed", "retry", "gave_up"}

TypeOK ==
    /\ queue \in Seq(Jobs)
    /\ worker \in [Workers -> Jobs \cup {Idle}]
    /\ phase \in [Jobs -> Phases]
    /\ slot \in {"absent", "computing", "ready"}
    /\ holder \in Jobs \cup {Unclaimed, Abandoned}
    /\ result \in {"pending", "ok", "failed", "released"}
    /\ owner \in OwnerStates

Init ==
    /\ queue = <<>>
    /\ worker = [w \in Workers |-> Idle]
    /\ phase = [j \in Jobs |-> "init"]
    /\ slot = "absent"
    /\ holder = Unclaimed
    /\ result = "pending"
    /\ owner = "idle"

Release(j) == worker' = [w \in Workers |-> IF worker[w] = j THEN Idle ELSE worker[w]]
Clear == slot' = IF slot = "computing" THEN "absent" ELSE slot

\* ── Owner fiber (outside the pool) ─────────────────────────────

\* A miss installs Computing and submits the owner's compute as job O.
OwnerMiss ==
    /\ owner = "idle"
    /\ slot = "absent"
    /\ slot' = "computing"
    /\ owner' = "waiting"
    /\ phase' = [phase EXCEPT ![Owner] = "queued"]
    /\ queue' = Append(queue, Owner)
    /\ UNCHANGED <<worker, holder, result>>

\* The owner returns on the settled outcome; a queued O is cancelled.
OwnerSeesResult ==
    /\ owner = "waiting"
    /\ result # "pending"
    /\ owner' = CASE result = "ok" -> "done"
                  [] result = "failed" -> "failed"
                  [] OTHER -> "retry"
    /\ phase' = IF phase[Owner] = "queued"
                THEN [phase EXCEPT ![Owner] = "cancelled"] ELSE phase
    /\ UNCHANGED <<queue, worker, slot, holder, result>>

\* The owner gives up (cancelled, or its window closed). It abandons an
\* unclaimed compute and clears the slot; a claimed one stays with its runner.
\* A queued O is cancelled; a running O is cancelled through ComputeReleased.
OwnerGivesUp ==
    /\ owner = "waiting"
    /\ owner' = "gave_up"
    /\ IF holder = Unclaimed
       THEN /\ holder' = Abandoned
            /\ Clear
       ELSE UNCHANGED <<holder, slot>>
    /\ phase' = IF phase[Owner] = "queued"
                THEN [phase EXCEPT ![Owner] = "cancelled"] ELSE phase
    /\ UNCHANGED <<queue, worker, result>>

\* Bug: the owner clears the slot even when a waiter runs the compute.
OwnerGivesUpClearsClaim ==
    /\ owner = "waiting"
    /\ owner' = "gave_up"
    /\ holder' = IF holder = Unclaimed THEN Abandoned ELSE holder
    /\ Clear
    /\ phase' = IF phase[Owner] = "queued"
                THEN [phase EXCEPT ![Owner] = "cancelled"] ELSE phase
    /\ UNCHANGED <<queue, worker, result>>

\* ── Pool ──────────────────────────────────────────────────────

WaiterSubmit(h) ==
    /\ phase[h] = "init"
    /\ phase' = [phase EXCEPT ![h] = "queued"]
    /\ queue' = Append(queue, h)
    /\ UNCHANGED <<worker, slot, holder, result, owner>>

\* A free worker takes the next job. A cancelled job ends at once.
Take(w) ==
    /\ worker[w] = Idle
    /\ queue # <<>>
    /\ LET j == Head(queue) IN
        IF phase[j] = "cancelled"
        THEN /\ phase' = [phase EXCEPT ![j] = "done"]
             /\ UNCHANGED worker
        ELSE /\ worker' = [worker EXCEPT ![w] = j]
             /\ phase' = [phase EXCEPT ![j] = IF j = Owner THEN "start" ELSE "lookup"]
    /\ queue' = Tail(queue)
    /\ UNCHANGED <<slot, holder, result, owner>>

\* O's job starts: claim the compute, or hand the worker back at once.
OwnerJobStart ==
    /\ phase[Owner] = "start"
    /\ IF holder = Unclaimed
       THEN /\ holder' = Owner
            /\ phase' = [phase EXCEPT ![Owner] = "computing"]
            /\ UNCHANGED worker
       ELSE /\ phase' = [phase EXCEPT ![Owner] = "done"]
            /\ Release(Owner)
            /\ UNCHANGED holder
    /\ UNCHANGED <<queue, slot, result, owner>>

\* Bug: O's job computes whether or not a waiter already claimed.
OwnerJobStartIgnoresClaim ==
    /\ phase[Owner] = "start"
    /\ holder' = IF holder = Unclaimed THEN Owner ELSE holder
    /\ phase' = [phase EXCEPT ![Owner] = "computing"]
    /\ UNCHANGED <<queue, worker, slot, result, owner>>

\* A waiter looks the key up on the worker it holds.
WaiterLookup(h) ==
    /\ phase[h] = "lookup"
    /\ CASE slot = "computing" /\ holder = Unclaimed ->
              /\ phase' = [phase EXCEPT ![h] = "claiming"]
              /\ UNCHANGED worker
         [] slot = "computing" ->
              /\ phase' = [phase EXCEPT ![h] = "waiting"]
              /\ UNCHANGED worker
         [] OTHER ->
              \* Hit, or a miss it handles as a new owner (out of model).
              /\ phase' = [phase EXCEPT ![h] = "done"]
              /\ Release(h)
    /\ UNCHANGED <<queue, slot, holder, result, owner>>

\* The claim is a separate step: the holder may have changed since the lookup.
WaiterClaim(h) ==
    /\ phase[h] = "claiming"
    /\ IF holder = Unclaimed
       THEN /\ holder' = h
            /\ phase' = [phase EXCEPT ![h] = "computing"]
       ELSE /\ phase' = [phase EXCEPT ![h] = "waiting"]
            /\ UNCHANGED holder
    /\ UNCHANGED <<queue, worker, slot, result, owner>>

\* Bug: before L4b a waiter polls whether or not the compute has started.
WaiterLookupNoClaim(h) ==
    /\ phase[h] = "lookup"
    /\ IF slot = "computing"
       THEN /\ phase' = [phase EXCEPT ![h] = "waiting"]
            /\ UNCHANGED worker
       ELSE /\ phase' = [phase EXCEPT ![h] = "done"]
            /\ Release(h)
    /\ UNCHANGED <<queue, slot, holder, result, owner>>

\* A polling waiter sees the slot leave Computing.
WaiterWakes(h) ==
    /\ phase[h] = "waiting"
    /\ slot # "computing"
    /\ phase' = [phase EXCEPT ![h] = "done"]
    /\ Release(h)
    /\ UNCHANGED <<queue, slot, holder, result, owner>>

\* The runner finishes: publish into a Computing slot, settle Ok.
ComputeOk(j) ==
    /\ phase[j] = "computing"
    /\ slot' = IF slot = "computing" THEN "ready" ELSE slot
    /\ result' = "ok"
    /\ phase' = [phase EXCEPT ![j] = "done"]
    /\ Release(j)
    /\ UNCHANGED <<queue, holder, owner>>

\* The runner raises: clear, settle Failed.
ComputeFails(j) ==
    /\ phase[j] = "computing"
    /\ Clear
    /\ result' = "failed"
    /\ phase' = [phase EXCEPT ![j] = "done"]
    /\ Release(j)
    /\ UNCHANGED <<queue, holder, owner>>

\* The runner is cancelled or its window closes: clear, settle Released.
ComputeReleased(j) ==
    /\ phase[j] = "computing"
    /\ Clear
    /\ result' = "released"
    /\ phase' = [phase EXCEPT ![j] = "done"]
    /\ Release(j)
    /\ UNCHANGED <<queue, holder, owner>>

\* Bug: a waiting job that claimed and fails exits without settling or clearing.
ComputeFailsOrphan(j) ==
    /\ phase[j] = "computing"
    /\ IF j = Owner
       THEN /\ Clear
            /\ result' = "failed"
       ELSE UNCHANGED <<slot, result>>
    /\ phase' = [phase EXCEPT ![j] = "done"]
    /\ Release(j)
    /\ UNCHANGED <<queue, holder, owner>>

\* ── Specs ─────────────────────────────────────────────────────

Common ==
    \/ OwnerMiss \/ OwnerSeesResult
    \/ \E h \in Waiters : WaiterSubmit(h) \/ WaiterWakes(h) \/ WaiterClaim(h)
    \/ \E w \in Workers : Take(w)
    \/ \E j \in Jobs : ComputeOk(j) \/ ComputeReleased(j)

Next ==
    \/ Common \/ OwnerGivesUp \/ OwnerJobStart
    \/ \E h \in Waiters : WaiterLookup(h)
    \/ \E j \in Jobs : ComputeFails(j)

NextNoClaim ==
    \/ Common \/ OwnerGivesUp \/ OwnerJobStart
    \/ \E h \in Waiters : WaiterLookupNoClaim(h)
    \/ \E j \in Jobs : ComputeFails(j)

NextIgnoreClaim ==
    \/ Common \/ OwnerGivesUp \/ OwnerJobStartIgnoresClaim
    \/ \E h \in Waiters : WaiterLookup(h)
    \/ \E j \in Jobs : ComputeFails(j)

NextOrphan ==
    \/ Common \/ OwnerGivesUp \/ OwnerJobStart
    \/ \E h \in Waiters : WaiterLookup(h)
    \/ \E j \in Jobs : ComputeFailsOrphan(j)

NextOwnerClearsClaim ==
    \/ Common \/ OwnerGivesUpClearsClaim \/ OwnerJobStart
    \/ \E h \in Waiters : WaiterLookup(h)
    \/ \E j \in Jobs : ComputeFails(j)

\* Running computes end, started jobs act, free workers take jobs, waiters
\* step, and the owner reads a settled outcome. Giving up is never forced.
Fairness(N) ==
    /\ \A j \in Jobs : WF_vars(phase[j] = "computing" /\ N /\ phase'[j] = "done")
    /\ WF_vars(phase[Owner] = "start" /\ N /\ phase'[Owner] # "start")
    /\ \A h \in Waiters :
         WF_vars(phase[h] \in {"lookup", "claiming"} /\ N /\ phase'[h] # phase[h])
    /\ \A h \in Waiters : WF_vars(WaiterWakes(h))
    /\ \A w \in Workers : WF_vars(Take(w))
    /\ WF_vars(OwnerSeesResult)

Spec == Init /\ [][Next]_vars /\ Fairness(Next)
SpecNoClaim == Init /\ [][NextNoClaim]_vars /\ Fairness(NextNoClaim)
SpecIgnoreClaim == Init /\ [][NextIgnoreClaim]_vars /\ Fairness(NextIgnoreClaim)
SpecOrphan == Init /\ [][NextOrphan]_vars /\ Fairness(NextOrphan)
SpecOwnerClearsClaim == Init /\ [][NextOwnerClearsClaim]_vars /\ Fairness(NextOwnerClearsClaim)

\* ── Properties ────────────────────────────────────────────────

\* Never: O queued while every worker is held by a waiter polling for it.
NoInversion ==
    ~ ( /\ phase[Owner] = "queued"
        /\ \A w \in Workers : worker[w] \in Waiters /\ phase[worker[w]] = "waiting" )

\* The compute for this epoch runs at most once at a time.
AtMostOneRunner ==
    Cardinality({j \in Jobs : phase[j] = "computing"}) <= 1

\* A claim with no settled outcome has its claimant still running.
ClaimHasRunner ==
    (holder \in Jobs /\ result = "pending") => phase[holder] = "computing"

\* An owner that gives up leaves a running claimant's slot in place.
ClaimantKeepsSlot ==
    (holder \in Waiters /\ phase[holder] = "computing") => slot = "computing"

\* A claimed compute always ends Ok, Failed or Released.
ClaimSettles == (holder \in Jobs) ~> (result # "pending")

\* An owner waiting for its compute always returns.
OwnerReturns == (owner = "waiting") ~> (owner # "waiting")

====
