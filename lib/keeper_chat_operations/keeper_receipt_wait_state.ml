type awaiting =
  | No_receipts
  | Receipt_pending
  | Receipts_arrived

let awaiting (obligations : Keeper_semantic_execution.receipt_obligation list) =
  match obligations with
  | [] -> No_receipts
  | _ :: _ ->
    if
      List.exists
        (fun (obligation : Keeper_semantic_execution.receipt_obligation) ->
          match obligation.state with
          | Keeper_semantic_execution.Pending -> true
          | Keeper_semantic_execution.Arrived
              (Keeper_semantic_execution.Receipt_in_outbox
              | Keeper_semantic_execution.Source_lost) -> false)
        obligations
    then Receipt_pending
    else Receipts_arrived
;;

type task =
  | Queued
  | Waiting
  | Ready
  | Running
  | Succeeded
  | Failed
  | Cancelled

let task (state : Keeper_chat_operation.state) awaiting =
  match state, awaiting with
  | Keeper_chat_operation.Queued, No_receipts -> Queued
  | Keeper_chat_operation.Queued, Receipt_pending -> Waiting
  | Keeper_chat_operation.Queued, Receipts_arrived -> Ready
  | Keeper_chat_operation.Running _, (No_receipts | Receipt_pending | Receipts_arrived) -> Running
  | Keeper_chat_operation.Succeeded _, (No_receipts | Receipt_pending | Receipts_arrived) -> Succeeded
  | Keeper_chat_operation.Failed _, (No_receipts | Receipt_pending | Receipts_arrived) -> Failed
  | Keeper_chat_operation.Cancelled _, (No_receipts | Receipt_pending | Receipts_arrived) -> Cancelled
;;

type receipt_presence =
  | Receipt_written
  | Receipt_not_written

type event =
  | Claim
  | Wait of receipt_presence
  | Resolve
  | Complete
  | Fail
  | Cancel
  | Restart

type outcome =
  | Moves_to of task
  | Stays
  | Rejected

(* Every pair is written out and no case is a wildcard, so a new task or event
   is a compile error here until each of its cells says what happens and which
   code path does it.

   Paths, by event:
   - Claim: [Keeper_chat_operation_store.claim_next]. [blocked_queued_scopes]
     skips an execution with a pending entry. Nothing is claimed otherwise
     when the slot is taken or the row is not [Queued].
   - Wait: [Keeper_chat_operation_store.defer_direct_checkpoint ~receipt_wait].
     Only a [Running] row is deferred; any other row is refused. A request
     another active execution owns is refused in the same transaction. A
     repeat of the exact earlier call confirms that commit and is not a new
     Wait.
   - Resolve: [Keeper_chat_operation_store.resolve_receipt]. It finds the
     execution by the request. A request nobody owns changes nothing. RFC 3.2
     writes Rejected for a task that never waited, but a notification names a
     request, not a task, so it cannot tell that task from one that ended, and
     RFC 4.4 makes a notice for a missing entry a no-op. The table says Stays
     for both.
   - Complete, Fail: [succeed_running], [fail_running].
   - Cancel: [cancel_queued], which settles the execution in the same
     transaction and so releases its entries.
   - Restart: [settle_running_without_executor ~cause:After_process_restart].
     A [Running] row with a durable continuation goes back to [Queued]
     instead; the table is for the row without one. *)
let step task event =
  match task, event with
  (* Queued *)
  | Queued, Claim -> Moves_to Running (* claim_next claims the row *)
  | Queued, Wait (Receipt_written | Receipt_not_written) ->
    Rejected (* defer_direct_checkpoint: the row is not Running *)
  | Queued, Resolve -> Stays (* resolve_receipt: no execution owns the request; RFC 3.2 writes Rejected, see above *)
  | Queued, Complete -> Rejected (* succeed_running: Not_running *)
  | Queued, Fail -> Rejected (* fail_running: Not_running *)
  | Queued, Cancel -> Moves_to Cancelled (* cancel_queued *)
  | Queued, Restart -> Stays (* settle_running_without_executor reads Running rows only *)
  (* Waiting *)
  | Waiting, Claim -> Rejected (* blocked_queued_scopes: a pending entry blocks the claim *)
  | Waiting, Wait (Receipt_written | Receipt_not_written) ->
    Rejected (* defer_direct_checkpoint: the row is not Running *)
  | Waiting, Resolve -> Moves_to Ready (* resolve_receipt: Pending becomes Arrived *)
  | Waiting, Complete -> Rejected (* succeed_running: Not_running *)
  | Waiting, Fail -> Rejected (* fail_running: Not_running *)
  | Waiting, Cancel -> Moves_to Cancelled (* cancel_queued; Settle Cancelled empties the entries *)
  | Waiting, Restart -> Stays (* the row and its entries are durable; no executor was running *)
  (* Ready *)
  | Ready, Claim -> Moves_to Running (* claim_next: every entry arrived, so nothing blocks *)
  | Ready, Wait (Receipt_written | Receipt_not_written) ->
    Rejected (* defer_direct_checkpoint: the row is not Running *)
  | Ready, Resolve -> Stays (* resolve_receipt: the entry is already Arrived *)
  | Ready, Complete -> Rejected (* succeed_running: Not_running *)
  | Ready, Fail -> Rejected (* fail_running: Not_running *)
  | Ready, Cancel -> Moves_to Cancelled (* cancel_queued; Settle Cancelled empties the entries *)
  | Ready, Restart -> Stays (* the row and its entries are durable; no executor was running *)
  (* Running *)
  | Running, Claim -> Rejected (* claim_next: the slot is taken *)
  | Running, Wait Receipt_written -> Moves_to Ready (* Await_receipt Arrived, then Suspend, in one transaction *)
  | Running, Wait Receipt_not_written -> Moves_to Waiting (* Await_receipt Pending, then Suspend, in one transaction *)
  | Running, Resolve -> Stays (* resolve_receipt: a running task's entries are Arrived, or it has none *)
  | Running, Complete -> Moves_to Succeeded (* succeed_running *)
  | Running, Fail -> Moves_to Failed (* fail_running *)
  | Running, Cancel -> Rejected (* cancel_queued: Not_queued *)
  | Running, Restart -> Moves_to Failed (* settle_running_without_executor, no continuation *)
  (* Succeeded *)
  | Succeeded, Claim -> Rejected (* claim_next reads Queued rows only *)
  | Succeeded, Wait (Receipt_written | Receipt_not_written) ->
    Rejected (* defer_direct_checkpoint: Not_running *)
  | Succeeded, Resolve -> Stays (* resolve_receipt: Settle emptied the entries *)
  | Succeeded, Complete -> Rejected (* succeed_running: Not_running *)
  | Succeeded, Fail -> Rejected (* fail_running: Not_running *)
  | Succeeded, Cancel -> Rejected (* cancel_queued: Not_queued *)
  | Succeeded, Restart -> Stays (* settle_running_without_executor reads Running rows only *)
  (* Failed *)
  | Failed, Claim -> Rejected (* claim_next reads Queued rows only *)
  | Failed, Wait (Receipt_written | Receipt_not_written) ->
    Rejected (* defer_direct_checkpoint: Not_running *)
  | Failed, Resolve -> Stays (* resolve_receipt: Settle emptied the entries *)
  | Failed, Complete -> Rejected (* succeed_running: Not_running *)
  | Failed, Fail -> Rejected (* fail_running: Not_running *)
  | Failed, Cancel -> Rejected (* cancel_queued: Not_queued *)
  | Failed, Restart -> Stays (* settle_running_without_executor reads Running rows only *)
  (* Cancelled *)
  | Cancelled, Claim -> Rejected (* claim_next reads Queued rows only *)
  | Cancelled, Wait (Receipt_written | Receipt_not_written) ->
    Rejected (* defer_direct_checkpoint: Not_running *)
  | Cancelled, Resolve -> Stays (* resolve_receipt: Settle emptied the entries *)
  | Cancelled, Complete -> Rejected (* succeed_running: Not_running *)
  | Cancelled, Fail -> Rejected (* fail_running: Not_running *)
  | Cancelled, Cancel -> Rejected (* cancel_queued: Not_queued *)
  | Cancelled, Restart -> Stays (* settle_running_without_executor reads Running rows only *)
;;

let all_tasks = [ Queued; Waiting; Ready; Running; Succeeded; Failed; Cancelled ]

let all_events =
  [ Claim
  ; Wait Receipt_written
  ; Wait Receipt_not_written
  ; Resolve
  ; Complete
  ; Fail
  ; Cancel
  ; Restart
  ]
;;

let task_to_string = function
  | Queued -> "queued"
  | Waiting -> "waiting"
  | Ready -> "ready"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Cancelled -> "cancelled"
;;

let event_to_string = function
  | Claim -> "claim"
  | Wait Receipt_written -> "wait (receipt written)"
  | Wait Receipt_not_written -> "wait (receipt not written)"
  | Resolve -> "resolve"
  | Complete -> "complete"
  | Fail -> "fail"
  | Cancel -> "cancel"
  | Restart -> "restart"
;;
