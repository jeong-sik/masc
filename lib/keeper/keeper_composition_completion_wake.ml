(* The result is committed before it is announced. [enqueue_durable_result]
   writes the pending snapshot first and only then updates the live queue, so
   an [Error] here means the submitter has not been told and the caller can
   report the delivery as failed instead of acknowledging one that never
   landed.

   The wake that follows is a hint, not the delivery: it reaches only a
   [Running] Keeper, and a paused or unregistered one is left alone, exactly
   as the Board, Fusion and delegation wakes do. Its failure is logged rather
   than raised because the stimulus is already committed and the Keeper reads
   it on its next admitted turn. Eio structural cancellation is re-raised. *)
let outcome_label : Keeper_event_queue.composition_terminal -> string = function
  | Keeper_event_queue.Composition_succeeded -> "succeeded"
  | Keeper_event_queue.Composition_failed _ -> "failed"
  | Keeper_event_queue.Composition_cancelled _ -> "cancelled"
;;

let deliver ~base_path ~keeper_name ~request_id ~composition_tool ~terminal =
  let completion =
    { Keeper_event_queue.cc_request_id = request_id
    ; cc_tool = composition_tool
    ; cc_terminal = terminal
    }
  in
  let stimulus : Keeper_event_queue.stimulus =
    { Keeper_event_queue.post_id =
        Keeper_event_queue.composition_completion_post_id completion
      (* [pending_entries] is urgency-sorted and stable, so [Normal] would put
         this behind every Board stimulus already queued. Measured on the live
         fleet: a Keeper with 151 pending would read its own result 151 turns
         after it landed, which is worse than the polling this replaces.

         [Immediate] is what [Hitl_resolved] uses, and for the same reason: an
         answer to something this Keeper asked for is not the same kind of
         event as somebody else posting to the Board. A Board post can be read
         later; work the Keeper started and is counting on cannot.

         [Fusion_completed] and [Delegate_completed] are still [Normal] and
         have the same argument for moving. Not changed here — each is its own
         call, and one of them wakes a different Keeper than the one that
         asked. *)
    ; urgency = Keeper_event_queue.Immediate
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Composition_completed completion
    }
  in
  match
    try
      Keeper_registry_event_queue.enqueue_durable_result ~base_path keeper_name stimulus
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Error reason ->
    Log.Keeper.error
      ~keeper_name
      "composition result commit failed request_id=%s tool=%s: %s"
      request_id
      composition_tool
      reason;
    Error reason
  | Ok () ->
    (* The level comes from the outcome: the commit succeeded either way, but
       a composition that could not finish is not routine for the Keeper that
       is still counting on it. *)
    (match terminal with
     | Keeper_event_queue.Composition_failed _
     | Keeper_event_queue.Composition_cancelled _ -> Log.Keeper.warn
     | Keeper_event_queue.Composition_succeeded -> Log.Keeper.info)
      ~keeper_name
      "composition result committed request_id=%s tool=%s outcome=%s"
      request_id
      composition_tool
      (outcome_label terminal);
    (try
       match
         Keeper_registry.wakeup_running
           ~intent:Keeper_registry.Reactive_signal
           ~base_path
           keeper_name
       with
       | Keeper_registry.Signaled -> ()
       | Keeper_registry.Deferred_unregistered ->
         Log.Keeper.info
           ~keeper_name
           "composition result wake deferred: submitter is no longer registered \
            request_id=%s"
           request_id
       | Keeper_registry.Deferred_not_running phase ->
         Log.Keeper.info
           ~keeper_name
           "composition result wake deferred: phase=%s request_id=%s"
           (Keeper_state_machine.phase_to_string phase)
           request_id
       | Keeper_registry.Deferred_lifecycle denial ->
         Log.Keeper.info
           ~keeper_name
           "composition result wake deferred by lifecycle: reason=%s request_id=%s"
           (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
           request_id
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         ~keeper_name
         "composition result wake hint failed after commit request_id=%s: %s"
         request_id
         (Printexc.to_string exn));
    Ok ()
;;

(* Which settled statuses are worth waking a Keeper for.

   Spelled out per status rather than defaulted: a status added to
   [Keeper_msg_async] must decide here whether the submitter hears about it,
   instead of inheriting silence — which is the failure this whole module
   exists to end. *)
let terminal_of_status : Keeper_msg_async.request_status -> Keeper_event_queue.composition_terminal option
  = function
  | Keeper_msg_async.Done { ok = true; _ } ->
    Some Keeper_event_queue.Composition_succeeded
  | Keeper_msg_async.Done { ok = false; body; _ } ->
    Some (Keeper_event_queue.Composition_failed body)
  | Keeper_msg_async.Lost { reason } ->
    Some (Keeper_event_queue.Composition_failed reason)
  | Keeper_msg_async.Persistence_failed { attempted_status; reason } ->
    Some
      (Keeper_event_queue.Composition_failed
         (Printf.sprintf "persisting %s failed: %s" attempted_status reason))
  | Keeper_msg_async.Cancelled { reason; cancelled_by } ->
    Some
      (Keeper_event_queue.Composition_cancelled
         (Printf.sprintf "%s: %s" cancelled_by reason))
  (* Not settled. Nothing to announce. *)
  | Keeper_msg_async.Queued
  | Keeper_msg_async.Running
  | Keeper_msg_async.Cancelling _ -> None
;;

let on_worker_settled ~base_path ~composition_tool settlement =
  match settlement with
  | Keeper_msg_async.Status_settlement
      { entry; durability = Keeper_msg_async.Durable; origin = _ } ->
    (match terminal_of_status entry.Keeper_msg_async.status with
     | None -> ()
     | Some terminal ->
       (match
          deliver
            ~base_path
            ~keeper_name:entry.Keeper_msg_async.submitted_by
            ~request_id:entry.Keeper_msg_async.request_id
            ~composition_tool
            ~terminal
        with
        | Ok () -> ()
        (* [deliver] already logged the reason. The result itself stays durable
           in the async request record, so the Keeper can still read it with
           keeper_composition_status; what was lost is being told. *)
        | Error _ -> ()))
  (* The store does not hold this settlement as canonical truth. Telling the
     Keeper its work succeeded on evidence that may not survive would be worse
     than leaving it to read the record. *)
  | Keeper_msg_async.Status_settlement
      { entry; durability = Keeper_msg_async.Volatile_persistence_failure; origin = _ } ->
    Log.Keeper.error
      ~keeper_name:entry.Keeper_msg_async.submitted_by
      "composition result not announced: settlement is visible but not durably \
       canonical request_id=%s tool=%s"
      entry.Keeper_msg_async.request_id
      composition_tool
  | Keeper_msg_async.Settlement_projection_error { attempted_entry; poll_result = _ } ->
    Log.Keeper.error
      ~keeper_name:attempted_entry.Keeper_msg_async.submitted_by
      "composition result not announced: settlement disagrees with canonical \
       request truth request_id=%s tool=%s"
      attempted_entry.Keeper_msg_async.request_id
      composition_tool
;;
