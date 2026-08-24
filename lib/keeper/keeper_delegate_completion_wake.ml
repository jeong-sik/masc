(* The answer is committed before it is announced. [enqueue_durable_result]
   writes the pending snapshot first and only then updates the live queue, so
   an [Error] here means the asker has not been told and the caller can report
   the delivery as failed instead of acknowledging one that never landed.

   The wake that follows is a hint, not the delivery: it reaches only a
   [Running] Keeper, and a paused or unregistered one is left alone, exactly
   as the Board and Fusion wakes do. Its failure is logged rather than raised
   because the stimulus is already committed and the Keeper reads it on its
   next admitted turn. Eio structural cancellation is re-raised. *)
let deliver ~base_path ~asked_by ~operation_id ~delegate ~terminal =
  let completion =
    { Keeper_event_queue.dc_operation_id = operation_id
    ; dc_keeper = delegate
    ; dc_terminal = terminal
    }
  in
  let outcome_label =
    match terminal with
    | Keeper_event_queue.Delegate_replied _ -> "replied"
    | Keeper_event_queue.Delegate_no_reply -> "no_reply"
    | Keeper_event_queue.Delegate_failed _ -> "failed"
  in
  let stimulus : Keeper_event_queue.stimulus =
    { Keeper_event_queue.post_id =
        Keeper_event_queue.delegate_completion_post_id completion
    ; urgency = Keeper_event_queue.Normal
    ; arrived_at = Time_compat.now ()
    ; payload = Keeper_event_queue.Delegate_completed completion
    }
  in
  match
    try Keeper_registry_event_queue.enqueue_durable_result ~base_path asked_by stimulus with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printexc.to_string exn)
  with
  | Error reason ->
    Log.Keeper.error
      ~keeper_name:asked_by
      "delegation answer commit failed operation_id=%s from=%s: %s"
      operation_id
      delegate
      reason;
    Error reason
  | Ok () ->
    (* The level comes from the outcome, as it does at the intake side: the
       commit succeeded either way, but a delegation that could not finish is
       not routine for the Keeper still waiting on it. *)
    (match terminal with
     | Keeper_event_queue.Delegate_failed _ -> Log.Keeper.warn
     | Keeper_event_queue.Delegate_replied _ | Keeper_event_queue.Delegate_no_reply ->
       Log.Keeper.info)
      ~keeper_name:asked_by
      "delegation answer committed operation_id=%s from=%s outcome=%s"
      operation_id
      delegate
      outcome_label;
    (try
       match
         Keeper_registry.wakeup_running
           ~intent:Keeper_registry.Reactive_signal
           ~base_path
           asked_by
       with
       | Keeper_registry.Signaled -> ()
       | Keeper_registry.Deferred_unregistered ->
         Log.Keeper.info
           ~keeper_name:asked_by
           "delegation answer wake deferred: asker is no longer registered \
            operation_id=%s"
           operation_id
       | Keeper_registry.Deferred_not_running phase ->
         Log.Keeper.info
           ~keeper_name:asked_by
           "delegation answer wake deferred: phase=%s operation_id=%s"
           (Keeper_state_machine.phase_to_string phase)
           operation_id
       | Keeper_registry.Deferred_lifecycle denial ->
         Log.Keeper.info
           ~keeper_name:asked_by
           "delegation answer wake deferred by lifecycle: reason=%s operation_id=%s"
           (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
           operation_id
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         ~keeper_name:asked_by
         "delegation answer wake hint failed after commit operation_id=%s: %s"
         operation_id
         (Printexc.to_string exn));
    Ok ()
;;
