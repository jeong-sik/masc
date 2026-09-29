(* Only a [masc.keeper_wake] payload queues anything, on the Keeper it names.
   [wake_keeper_name] is [None] for every other kind and for a malformed wake
   payload (logged there); dispatch refuses a malformed one before it
   enqueues, so neither has a queued wake to remove. The queue cancellation
   carries the canceller and the reason, so the Keeper's queue record says
   who withdrew the occurrence and why. An occurrence a running turn was given
   is withdrawn too: the cancel may come from inside that turn (a Keeper
   cancelling the schedule that woke it) or from the TUI mid-turn. That turn
   still finishes on what it was given, so such an occurrence's record reads
   as cancelled even though a turn saw it; the turn's terminal answers
   [Turn_selection_withdrawn] instead of committing a receipt. *)
let run config (request : Schedule_domain.schedule_request)
      (cancellation : Schedule_domain.cancellation)
  =
  match Schedule_payload_projection.wake_keeper_name request with
  | None -> Ok ()
  | Some keeper_name ->
    (match
       Keeper_registry_event_queue.cancel_scheduled_wakes_result
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
