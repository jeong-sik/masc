(* Only a [masc.keeper_wake] payload queues anything, on the Keeper it names.
   [wake_keeper_name] is [None] for every other kind and for a malformed wake
   payload (logged there); dispatch refuses a malformed one before it
   enqueues, so neither has a queued wake to remove. The queue cancellation
   carries the canceller and the reason, so the Keeper's queue record says
   why the occurrence never ran. An occurrence a running turn already took
   stays for that turn to ACK: the cancel may come from inside that turn (a
   Keeper cancelling the schedule that woke it) or from the TUI mid-turn,
   and the row turning [Cancelled] is what stops later occurrences. *)
let run config (request : Schedule_domain.schedule_request)
      (cancellation : Schedule_domain.cancellation)
  =
  match Schedule_payload_projection.wake_keeper_name request with
  | None -> Ok ()
  | Some keeper_name ->
    (match
       Keeper_registry_event_queue.cancel_untaken_scheduled_wakes_result
         ~base_path:config.Workspace.base_path
         keeper_name
         ~applied_at:(Time_compat.now ())
         ~schedule_ids:[ request.schedule_id ]
         ~reason:
           (Printf.sprintf
              "schedule %s cancelled by %s: %s"
              request.schedule_id
              cancellation.cancelled_by.id
              cancellation.reason)
     with
     | Error _ as error -> error
     | Ok 0 -> Ok ()
     | Ok withdrawn ->
       Log.Keeper.info
         ~keeper_name
         "schedule cancel withdrew %d queued wake(s) schedule_id=%s"
         withdrawn
         request.schedule_id;
       Ok ())
;;
