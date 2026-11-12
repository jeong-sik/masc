---------------------- MODULE KeeperReceiptWait ----------------------
(***************************************************************************)
(* One Keeper. A chat task ends its turn while it waits for the receipt of *)
(* a background run, and it is not claimed again until that receipt        *)
(* exists (docs/rfc/RFC-keeper-turn-ends-while-waiting-for-a-receipt-      *)
(* state-machine.md, candidate (b) of RFC-a-keeper-works-while-a-long-     *)
(* execute-runs).                                                          *)
(*                                                                         *)
(* This is a design model, written before any code. It checks the proposed *)
(* states and transitions of one Keeper's chat-task slot and of the        *)
(* receipts, and the ownership record that keeps another run from          *)
(* consuming a receipt a task is waiting for. The code it describes does   *)
(* not exist yet, except the parts named under "Existing" below.           *)
(*                                                                         *)
(* Spec <-> code, at 60cfd89ce917:                                         *)
(*                                                                         *)
(*   spec                  | code                                          *)
(*   ----------------------+---------------------------------------------- *)
(*   slot                  | Keeper_owner.turn_in_flight, one cell         *)
(*                         |   (keeper_owner.ml:451, gate :1802-1816)      *)
(*   task queued/running/  | Keeper_chat_operation_reducer states          *)
(*   succeeded/failed/     |   (keeper_chat_operation_reducer.ml:53-100)   *)
(*   cancelled             |                                               *)
(*   Claim                 | Chat_operation_store.claim_next, which does   *)
(*                         |   nothing while a row is running              *)
(*                         |   (keeper_chat_operation_store.ml:1890-1895)  *)
(*   Cancel                | cancel_queued, settles the semantic record in *)
(*                         |   the same transaction (store :3220, :3160)   *)
(*   waiting               | PROPOSED: a sixth blocked reason next to the  *)
(*                         |   five of blocked_queued_scopes (store :1731) *)
(*   ready                 | PROPOSED: the wait is resolved, the row is    *)
(*                         |   claimable, as Gate_wait with a resolution   *)
(*                         |   (store :1736)                               *)
(*   Wait (running->       | PROPOSED: the turn ends and the row goes back *)
(*   waiting/ready)        |   to Queued, as defer_direct_input_wait       *)
(*                         |   (store :2404-2444)                          *)
(*   Fail on Restart       | a Running row without a continuation fails    *)
(*                         |   (store :3456-3459)                          *)
(*   Restart of a resumed  | a Running row with a continuation goes back to *)
(*   task                  |   Queued and keeps what it owns               *)
(*                         |   (store :3415, requeue_continuation_with_db) *)
(*   req running           | Keeper_msg_async request, worker on the       *)
(*                         |   server-lifetime switch                      *)
(*                         |   (keeper_execute_background.ml:253-271)      *)
(*   req written           | Outbox.retain of the finished or unfinished   *)
(*                         |   receipt (keeper_execute_background.ml:109)  *)
(*   req orphaned          | durable active request, worker gone; boot     *)
(*                         |   writes the unfinished receipt               *)
(*                         |   (keeper_execute_background.ml:334-353,      *)
(*                         |   server_bootstrap_maintenance.ml:375)        *)
(*   req acked             | Outbox.acknowledge, only on Completed         *)
(*                         |   (keeper_client_tool_outbox.ml:592-607)      *)
(*   loaded                | Outbox.load of a run: one snapshot            *)
(*                         |   (keeper_client_tool_outbox.ml:545-555)      *)
(*   owns                  | PROPOSED: the ownership record. Loads skip    *)
(*                         |   receipts another task owns                  *)
(*                                                                         *)
(* Abstractions. The check of the request and the write of the outbox are  *)
(* two stores in the code; here each action is one step, and the gap       *)
(* between Retain and Resolve is a step of its own. Claim picks any        *)
(* claimable task, not the FIFO head, so the model has more behaviours     *)
(* than the code. Complete is the ACK and the settle in one step; the code *)
(* does them one after the other. A receipt is an id here; its content is  *)
(* not. The patrol run and the other lanes are one holder, "patrol". Edit, *)
(* batch members, the vendor session and the checkpoint are not modelled.  *)
(* A request is a background Execute run or a Keeper wake whose delivery  *)
(* is receipt (keeper_schedule_receipt.ml). The wake is "running" until    *)
(* its schedule row ends: Retain is the consumer writing the receipt       *)
(* (server_schedule_consumers.ml dispatch_keeper_receipt), and             *)
(* EndWithoutReceipt is a row that ends without one (a rejected wake, a    *)
(* cancelled row). The sweep then writes the unfinished receipt            *)
(* (keeper_receipt_wait_sweep.ml), as RecoverUnfinished does for a run.    *)
(* The model assumes boot recovery writes the unfinished receipt. The code *)
(* logs a warning and writes none when the active inventory is unreadable  *)
(* (keeper_execute_background.ml:336-339); that case is RestartLoses.      *)
(*                                                                         *)
(* Bug models. B1 to B7 each add one action to Next. B8 drops a fairness   *)
(* condition instead. The clean model keeps every safety invariant, and    *)
(* each buggy cfg lists the one invariant, or the one property, that has   *)
(* to catch its bug alone.                                                 *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS T1, T2, R1, R2, MaxRestarts, MaxPatrols

Tasks == {T1, T2}
Requests == {R1, R2}
None == "none"

ASSUME BoundsAreNat == MaxRestarts \in Nat /\ MaxPatrols \in Nat

TaskStates ==
    {"queued", "waiting", "ready", "running", "succeeded", "failed", "cancelled"}
Terminal == {"succeeded", "failed", "cancelled"}
ReqStates == {"idle", "running", "orphaned", "written", "acked", "lost"}
SlotValues == {"free", "patrol"} \cup Tasks

VARIABLES
    task,       \* [Tasks -> TaskStates]
    awaiting,   \* the requests a waiting or ready task waits for
    owns,       \* the ownership record: requests a task owns
    req,        \* [Requests -> ReqStates]
    slot,       \* who holds the Keeper's one turn slot
    loaded,     \* the receipts the slot holder's run carries
    finished,   \* history: the terminal state a task reached
    lastwait,   \* history: the requests a task last waited for
    requeued,   \* history: tasks a restart returned to the queue while running
    restarts,
    patrols

vars == << task, awaiting, owns, req, slot, loaded, finished, lastwait,
           restarts, patrols, requeued >>

TypeOK ==
    /\ task \in [Tasks -> TaskStates]
    /\ awaiting \in [Tasks -> SUBSET Requests]
    /\ owns \in [Tasks -> SUBSET Requests]
    /\ req \in [Requests -> ReqStates]
    /\ slot \in SlotValues
    /\ loaded \subseteq Requests
    /\ finished \in [Tasks -> Terminal \cup {None}]
    /\ lastwait \in [Tasks -> SUBSET Requests]
    /\ requeued \subseteq Tasks
    /\ restarts \in 0..MaxRestarts
    /\ patrols \in 0..MaxPatrols

Init ==
    /\ task = [t \in Tasks |-> "queued"]
    /\ awaiting = [t \in Tasks |-> {}]
    /\ owns = [t \in Tasks |-> {}]
    /\ req = [r \in Requests |-> "idle"]
    /\ slot = "free"
    /\ loaded = {}
    /\ finished = [t \in Tasks |-> None]
    /\ lastwait = [t \in Tasks |-> {}]
    /\ requeued = {}
    /\ restarts = 0
    /\ patrols = 0

Owned == UNION {owns[t] : t \in Tasks}

\* What a run of [who] carries: written receipts that no other task owns.
\* A patrol run is "patrol", so it carries only receipts nobody owns.
Visible(r, who) ==
    /\ req[r] = "written"
    /\ \A t \in Tasks : r \in owns[t] => t = who

\* A completed run removes the receipts it carried.
Ack(set) ==
    [r \in Requests |-> IF r \in set /\ req[r] = "written" THEN "acked" ELSE req[r]]

(*-------------------------- normal actions ----------------------------*)

\* The Keeper claims a task that is claimable. A waiting task is not.
Claim(t) ==
    /\ slot = "free"
    /\ task[t] \in {"queued", "ready"}
    /\ task' = [task EXCEPT ![t] = "running"]
    /\ awaiting' = [awaiting EXCEPT ![t] = {}]
    /\ slot' = t
    /\ loaded' = {r \in Requests : Visible(r, t)}
    /\ UNCHANGED << owns, req, finished, lastwait, restarts, patrols, requeued >>

\* The holder of the slot starts a background run.
StartRun(r) ==
    /\ slot # "free"
    /\ req[r] = "idle"
    /\ req' = [req EXCEPT ![r] = "running"]
    /\ UNCHANGED << task, awaiting, owns, slot, loaded, finished, lastwait,
                    restarts, patrols, requeued >>

\* The worker ends and its receipt is retained. A raised or cancelled worker
\* retains an unfinished receipt, so this one step covers all of them.
Retain(r) ==
    /\ req[r] = "running"
    /\ req' = [req EXCEPT ![r] = "written"]
    /\ UNCHANGED << task, awaiting, owns, slot, loaded, finished, lastwait,
                    restarts, patrols, requeued >>

\* After a restart, boot writes the unfinished receipt of a request whose
\* worker died with the server.
RecoverUnfinished(r) ==
    /\ req[r] = "orphaned"
    /\ req' = [req EXCEPT ![r] = "written"]
    /\ UNCHANGED << task, awaiting, owns, slot, loaded, finished, lastwait,
                    restarts, patrols, requeued >>

\* A schedule row that delivers a receipt ends without writing one: its wake
\* is rejected, or the row is cancelled. No server restart is involved, which
\* is what separates this from Restart. The sweep writes the unfinished
\* receipt, so RecoverUnfinished applies.
EndWithoutReceipt(r) ==
    /\ req[r] = "running"
    /\ req' = [req EXCEPT ![r] = "orphaned"]
    /\ UNCHANGED << task, awaiting, owns, slot, loaded, finished, lastwait,
                    restarts, patrols, requeued >>

\* The running task asks to wait for a set of requests. Its turn ends in the
\* same step. Every request must have a source, and no task may own any of
\* them yet. The task is claimable at once when every receipt is written.
Wait(t, rs) ==
    /\ slot = t
    /\ task[t] = "running"
    /\ rs # {}
    /\ \A r \in rs : req[r] \in {"running", "written"}
    /\ rs \cap Owned = {}
    /\ task' = [task EXCEPT ![t] = IF \A r \in rs : req[r] = "written" THEN "ready" ELSE "waiting"]
    /\ awaiting' = [awaiting EXCEPT ![t] = rs]
    /\ owns' = [owns EXCEPT ![t] = @ \cup rs]
    /\ lastwait' = [lastwait EXCEPT ![t] = rs]
    /\ slot' = "free"
    /\ loaded' = {}
    /\ UNCHANGED << req, finished, restarts, patrols, requeued >>

\* Every receipt of the awaited requests exists, so the wait is resolved. The
\* guard on the task state is the compare-and-set of the store row.
Resolve(t) ==
    /\ task[t] = "waiting"
    /\ \A r \in awaiting[t] : req[r] = "written"
    /\ task' = [task EXCEPT ![t] = "ready"]
    /\ UNCHANGED << awaiting, owns, req, slot, loaded, finished, lastwait,
                    restarts, patrols, requeued >>

\* The turn completes: its receipts are removed, and the task releases what
\* it owns.
Complete(t) ==
    /\ slot = t
    /\ task[t] = "running"
    /\ task' = [task EXCEPT ![t] = "succeeded"]
    /\ finished' = [finished EXCEPT ![t] = "succeeded"]
    /\ owns' = [owns EXCEPT ![t] = {}]
    /\ req' = Ack(loaded)
    /\ slot' = "free"
    /\ loaded' = {}
    /\ UNCHANGED << awaiting, lastwait, restarts, patrols, requeued >>

\* The turn fails or an operator interrupts it. Nothing is removed. The task
\* releases what it owns, so the receipts go to the next run.
Fail(t) ==
    /\ slot = t
    /\ task[t] = "running"
    /\ task' = [task EXCEPT ![t] = "failed"]
    /\ finished' = [finished EXCEPT ![t] = "failed"]
    /\ owns' = [owns EXCEPT ![t] = {}]
    /\ slot' = "free"
    /\ loaded' = {}
    /\ UNCHANGED << awaiting, req, lastwait, restarts, patrols, requeued >>

\* A task that is not running is cancelled, and it releases what it owns in
\* the same step.
Cancel(t) ==
    /\ task[t] \in {"queued", "waiting", "ready"}
    /\ task' = [task EXCEPT ![t] = "cancelled"]
    /\ finished' = [finished EXCEPT ![t] = "cancelled"]
    /\ awaiting' = [awaiting EXCEPT ![t] = {}]
    /\ owns' = [owns EXCEPT ![t] = {}]
    /\ UNCHANGED << req, slot, loaded, lastwait, restarts, patrols, requeued >>

PatrolStart ==
    /\ slot = "free"
    /\ patrols < MaxPatrols
    /\ slot' = "patrol"
    /\ loaded' = {r \in Requests : Visible(r, "patrol")}
    /\ patrols' = patrols + 1
    /\ UNCHANGED << task, awaiting, owns, req, finished, lastwait, restarts, requeued >>

PatrolEnd ==
    /\ slot = "patrol"
    /\ req' = Ack(loaded)
    /\ slot' = "free"
    /\ loaded' = {}
    /\ UNCHANGED << task, awaiting, owns, finished, lastwait, restarts, patrols, requeued >>

\* A running task that was claimed after a wait carries the continuation it
\* resumed from. A running task that never waited has none.
Resumed(t) == task[t] = "running" /\ lastwait[t] # {}
NoContinuation(t) == task[t] = "running" /\ lastwait[t] = {}

\* The server restarts. Rows and receipts are durable. A running turn, its
\* snapshot and the workers are not. A running row without a continuation
\* fails and releases what it owns. A running row with one goes back to the
\* queue and keeps what it owns, as Requeue_continuation does (store :3415).
\* It could only be claimed because every request it owns had its receipt,
\* so it is ready, not waiting. A worker's request stays active until boot
\* writes its receipt. [lost] is the state a running request gets.
RestartWith(lost) ==
    /\ restarts < MaxRestarts
    /\ task' = [t \in Tasks |->
                  IF Resumed(t) THEN "ready"
                  ELSE IF NoContinuation(t) THEN "failed"
                  ELSE task[t]]
    /\ awaiting' = [t \in Tasks |-> IF Resumed(t) THEN lastwait[t] ELSE awaiting[t]]
    /\ finished' = [t \in Tasks |-> IF NoContinuation(t) THEN "failed" ELSE finished[t]]
    /\ owns' = [t \in Tasks |-> IF NoContinuation(t) THEN {} ELSE owns[t]]
    /\ requeued' = requeued \cup {t \in Tasks : Resumed(t)}
    /\ req' = [r \in Requests |-> IF req[r] = "running" THEN lost ELSE req[r]]
    /\ slot' = "free"
    /\ loaded' = {}
    /\ restarts' = restarts + 1
    /\ UNCHANGED << lastwait, patrols >>

Restart == RestartWith("orphaned")

Next ==
    \/ \E t \in Tasks : Claim(t)
    \/ \E r \in Requests : StartRun(r)
    \/ \E r \in Requests : Retain(r)
    \/ \E r \in Requests : EndWithoutReceipt(r)
    \/ \E r \in Requests : RecoverUnfinished(r)
    \/ \E t \in Tasks, rs \in SUBSET Requests : Wait(t, rs)
    \/ \E t \in Tasks : Resolve(t)
    \/ \E t \in Tasks : Complete(t)
    \/ \E t \in Tasks : Fail(t)
    \/ \E t \in Tasks : Cancel(t)
    \/ PatrolStart
    \/ PatrolEnd
    \/ Restart

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ \A r \in Requests : WF_vars(Retain(r))
    /\ \A r \in Requests : WF_vars(RecoverUnfinished(r))
    /\ \A t \in Tasks : WF_vars(Resolve(t))

(*--------------------------- invariants -------------------------------*)

\* The Keeper has one turn slot. The slot names the running task, and a
\* running task holds the slot.
SlotMatchesTask ==
    /\ slot \in Tasks => task[slot] = "running"
    /\ \A t \in Tasks : task[t] = "running" => slot = t

\* A request is owned by at most one task.
OneOwner ==
    \A t1, t2 \in Tasks : t1 # t2 => owns[t1] \cap owns[t2] = {}

\* A terminal task owns nothing, so a receipt is never held for a task that
\* cannot take it.
OwnerIsLive ==
    \A t \in Tasks : task[t] \in Terminal => owns[t] = {}

\* A waiting or ready task names requests it owns, and no other task does.
WaitingHasRequest ==
    \A t \in Tasks :
        /\ task[t] \in {"waiting", "ready"} <=> awaiting[t] # {}
        /\ awaiting[t] \subseteq owns[t]

\* A waiting task has something to wait for in every request: a worker, a
\* request that boot will write a receipt for, or a receipt.
WaitingHasSource ==
    \A t \in Tasks :
        task[t] = "waiting" => \A r \in awaiting[t] : req[r] \in {"running", "orphaned", "written"}

\* A ready task finds its receipt in the outbox.
ReadyHasReceipt ==
    \A t \in Tasks : task[t] = "ready" => \A r \in awaiting[t] : req[r] = "written"

\* A task is claimed only after the receipts it owns exist.
ClaimedHasReceipt ==
    \A t \in Tasks :
        task[t] = "running" => \A r \in owns[t] : req[r] = "written"

\* A task that reached a terminal state stays there.
TerminalIsFinal ==
    \A t \in Tasks : finished[t] # None => task[t] = finished[t]

Safety ==
    /\ TypeOK
    /\ SlotMatchesTask
    /\ OneOwner
    /\ OwnerIsLive
    /\ WaitingHasRequest
    /\ WaitingHasSource
    /\ ReadyHasReceipt
    /\ ClaimedHasReceipt
    /\ TerminalIsFinal

\* A waiting task stops waiting. The receipt reaches the outbox, and the task
\* becomes claimable, or the task is cancelled.
WaiterResolves ==
    \A t \in Tasks : (task[t] = "waiting") ~> (task[t] # "waiting")

(*------------------------ reachability guards -------------------------*)

\* The clean model has to reach the paths the invariants guard. Each of these
\* is false of the clean model, and its cfg expects a violation, so it goes
\* red the day a path becomes unreachable and the invariants above pass for
\* nothing.

\* A task waits, is claimed again with its receipt, and completes.
WaitThenSucceedUnreachable ==
    \A t \in Tasks : ~(finished[t] = "succeeded" /\ lastwait[t] # {})

\* A task waits while its request is active but its worker is gone.
WaitOnOrphanUnreachable ==
    \A t \in Tasks : task[t] = "waiting" => \A r \in awaiting[t] : req[r] # "orphaned"

\* The receipt a cancelled task waited for is in the outbox, whether it was
\* written before the cancel or after it.
LateReceiptAfterCancelUnreachable ==
    \A t \in Tasks :
        ~(finished[t] = "cancelled" /\ \E r \in lastwait[t] : req[r] = "written")

\* A task waits and is claimed with its receipt, a restart returns it to the
\* queue with what it owns, and it is claimed again and completes.
RestartRequeueThenSucceedUnreachable ==
    \A t \in Tasks : ~(finished[t] = "succeeded" /\ t \in requeued)

(*---------------------------- bug models ------------------------------*)

\* B1. The Keeper claims a task that still waits. The receipt is pending
\* and the task owns it.
ClaimWhileWaiting(t) ==
    /\ slot = "free"
    /\ task[t] = "waiting"
    /\ task' = [task EXCEPT ![t] = "running"]
    /\ awaiting' = [awaiting EXCEPT ![t] = {}]
    /\ slot' = t
    /\ loaded' = {r \in Requests : Visible(r, t)}
    /\ UNCHANGED << owns, req, finished, lastwait, restarts, patrols, requeued >>

NextClaimBuggy == Next \/ (\E t \in Tasks : ClaimWhileWaiting(t))
SpecClaimBuggy == Init /\ [][NextClaimBuggy]_vars

\* B2. A second task waits for a request another task already owns, so one
\* receipt is claimed twice. The store has no unique index on the request.
DuplicateWait(t, rs) ==
    /\ slot = t
    /\ task[t] = "running"
    /\ rs # {}
    /\ \A r \in rs : req[r] \in {"running", "written"}
    /\ \E u \in Tasks : u # t /\ rs \cap owns[u] # {}
    /\ task' = [task EXCEPT ![t] = IF \A r \in rs : req[r] = "written" THEN "ready" ELSE "waiting"]
    /\ awaiting' = [awaiting EXCEPT ![t] = rs]
    /\ owns' = [owns EXCEPT ![t] = @ \cup rs]
    /\ lastwait' = [lastwait EXCEPT ![t] = rs]
    /\ slot' = "free"
    /\ loaded' = {}
    /\ UNCHANGED << req, finished, restarts, patrols, requeued >>

NextDuplicateWaitBuggy == Next \/ (\E t \in Tasks, rs \in SUBSET Requests : DuplicateWait(t, rs))
SpecDuplicateWaitBuggy == Init /\ [][NextDuplicateWaitBuggy]_vars

\* B3. A run loads receipts without asking who owns them, and its completed
\* turn removes a receipt a task waits for. One load site of the outbox that
\* skips the owner filter is enough.
PatrolStartLoadsAll ==
    /\ slot = "free"
    /\ patrols < MaxPatrols
    /\ slot' = "patrol"
    /\ loaded' = {r \in Requests : req[r] = "written"}
    /\ patrols' = patrols + 1
    /\ UNCHANGED << task, awaiting, owns, req, finished, lastwait, restarts, requeued >>

NextUnfilteredLoadBuggy == Next \/ PatrolStartLoadsAll
SpecUnfilteredLoadBuggy == Init /\ [][NextUnfilteredLoadBuggy]_vars

\* B4. A late receipt revives a cancelled task. The lookup from request to
\* task is an index nobody cleans when the task is cancelled.
ReviveFromStaleIndex(t) ==
    /\ task[t] = "cancelled"
    /\ lastwait[t] # {}
    /\ \A r \in lastwait[t] : req[r] = "written"
    /\ task' = [task EXCEPT ![t] = "ready"]
    /\ awaiting' = [awaiting EXCEPT ![t] = lastwait[t]]
    /\ owns' = [owns EXCEPT ![t] = @ \cup lastwait[t]]
    /\ UNCHANGED << req, slot, loaded, finished, lastwait, restarts, patrols, requeued >>

NextReviveBuggy == Next \/ (\E t \in Tasks : ReviveFromStaleIndex(t))
SpecReviveBuggy == Init /\ [][NextReviveBuggy]_vars

\* B5. A cancelled task keeps its ownership record, so the receipt it waited
\* for is hidden from every run and nobody takes it.
CancelKeepsOwner(t) ==
    /\ task[t] \in {"queued", "waiting", "ready"}
    /\ task' = [task EXCEPT ![t] = "cancelled"]
    /\ finished' = [finished EXCEPT ![t] = "cancelled"]
    /\ awaiting' = [awaiting EXCEPT ![t] = {}]
    /\ UNCHANGED << owns, req, slot, loaded, lastwait, restarts, patrols, requeued >>

NextCancelKeepsOwnerBuggy == Next \/ (\E t \in Tasks : CancelKeepsOwner(t))
SpecCancelKeepsOwnerBuggy == Init /\ [][NextCancelKeepsOwnerBuggy]_vars

\* B6. A restart loses a request that has no durable record, as when the
\* active inventory cannot be read. No worker and no receipt remain, and the
\* waiting task waits for nothing.
RestartLoses == RestartWith("lost")

NextRestartLosesBuggy == Next \/ RestartLoses
SpecRestartLosesBuggy == Init /\ [][NextRestartLosesBuggy]_vars

\* B7. A second notice of the same receipt puts a running task back in the
\* queue, as Requeue_continuation does for a Running row. The slot still
\* names the task.
DuplicateResolveRequeues(t) ==
    /\ task[t] = "running"
    /\ \E r \in owns[t] : req[r] = "written"
    /\ task' = [task EXCEPT ![t] = "ready"]
    /\ awaiting' = [awaiting EXCEPT ![t] = {r \in owns[t] : req[r] = "written"}]
    /\ UNCHANGED << owns, req, slot, loaded, finished, lastwait, restarts, patrols, requeued >>

NextDuplicateResolveBuggy == Next \/ (\E t \in Tasks : DuplicateResolveRequeues(t))
SpecDuplicateResolveBuggy == Init /\ [][NextDuplicateResolveBuggy]_vars

\* B8. The notice that the receipt exists is never delivered: neither the
\* hint after Outbox.retain nor the maintenance pulse that scans the outbox
\* (server_bootstrap_maintenance.ml:786, :803) reaches the task. Every
\* safety invariant still holds, since nothing wrong happens. The task waits
\* for good, and WaiterResolves is the property that sees it.
SpecWakeNeverDelivered ==
    /\ Init
    /\ [][Next]_vars
    /\ \A r \in Requests : WF_vars(Retain(r))
    /\ \A r \in Requests : WF_vars(RecoverUnfinished(r))

\* B1 to B7 at once.
NextBuggy ==
    \/ Next
    \/ \E t \in Tasks : ClaimWhileWaiting(t)
    \/ \E t \in Tasks, rs \in SUBSET Requests : DuplicateWait(t, rs)
    \/ PatrolStartLoadsAll
    \/ \E t \in Tasks : ReviveFromStaleIndex(t)
    \/ \E t \in Tasks : CancelKeepsOwner(t)
    \/ RestartLoses
    \/ \E t \in Tasks : DuplicateResolveRequeues(t)

SpecBuggy == Init /\ [][NextBuggy]_vars

============================================================================
