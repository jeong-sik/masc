(** Keeper_chat_consumer — standalone polling fiber for queue drain. *)

let poll_interval_sec =
  match Sys.getenv_opt "MASC_KEEPER_QUEUE_POLL_SEC" with
  | Some s -> (
      try float_of_string s with Failure _ -> 1.0)
  | None -> 1.0

type dispatch_state = {
  mutex : Eio.Mutex.t;
  running_by_keeper : (string, unit) Hashtbl.t;
}

let create_dispatch_state () =
  { mutex = Eio.Mutex.create (); running_by_keeper = Hashtbl.create 16 }

let with_dispatch_state state f =
  Eio.Mutex.use_rw ~protect:true state.mutex f

let is_dispatching state keeper_name =
  with_dispatch_state state (fun () ->
      Hashtbl.mem state.running_by_keeper keeper_name)

let mark_dispatching state keeper_name =
  with_dispatch_state state (fun () ->
      if Hashtbl.mem state.running_by_keeper keeper_name
      then false
      else (
        Hashtbl.replace state.running_by_keeper keeper_name ();
        true))

let clear_dispatching state keeper_name =
  Eio.Cancel.protect (fun () ->
      with_dispatch_state state (fun () ->
          Hashtbl.remove state.running_by_keeper keeper_name))

module For_testing = struct
  type nonrec dispatch_state = dispatch_state

  let create_dispatch_state = create_dispatch_state
  let is_dispatching = is_dispatching
  let mark_dispatching = mark_dispatching
  let clear_dispatching = clear_dispatching
end

(* Single broadcast site for every queue-depth-affecting mutation this module
   performs (lease/ack/nack — [enqueue]'s callers broadcast their own, since
   they already have the post-enqueue length in hand). Keeping it here rather
   than scattered across each [`Leased]/[`Acked]/[`Requeued] call site avoids
   an N-of-M gap where a future new call site forgets to broadcast. *)
let broadcast_queue_changed ~keeper_name =
  Keeper_chat_broadcast.queue_changed ~keeper_name
    ~depth:(Keeper_chat_queue.length ~keeper_name)
    ()

let ack_or_warn ~keeper_name ~lease_id =
  match Keeper_chat_queue.ack ~keeper_name ~lease_id with
  | `Acked -> broadcast_queue_changed ~keeper_name
  | `Unknown_lease ->
      Log.Keeper.warn
        "keeper_chat_consumer: ack found no matching lease=%s for keeper=%s \
         (already acked/nacked?)"
        lease_id
        keeper_name
  | `Persist_failed msg ->
      Log.Keeper.warn
        "keeper_chat_consumer: ack persist failed for keeper=%s lease=%s: %s"
        keeper_name
        lease_id
        msg

(* Best-effort: called both on a genuine dispatch failure and (via
   [Eio.Cancel.protect]) while this fiber is itself being cancelled from
   outside, so a [Persistence_failed]/`Unknown_lease] result here is logged,
   not retried — retrying I/O under an active cancellation would just raise
   [Eio.Cancel.Cancelled] again. Worst case the message stays recorded as an
   outstanding lease in the durable snapshot and is requeued by the next
   [Keeper_chat_queue.configure_persistence] (process restart). *)
let nack_or_warn ~keeper_name ~lease_id =
  match Keeper_chat_queue.nack ~keeper_name ~lease_id with
  | `Requeued -> broadcast_queue_changed ~keeper_name
  | `Unknown_lease ->
      Log.Keeper.warn
        "keeper_chat_consumer: nack found no matching lease=%s for keeper=%s \
         (already acked/nacked?)"
        lease_id
        keeper_name
  | `Persist_failed msg ->
      Log.Keeper.warn
        "keeper_chat_consumer: nack persist failed for keeper=%s lease=%s: %s"
        keeper_name
        lease_id
        msg

(* Races [handle_turn] against [dispatch_deadline_sec] so one wedged turn
   cannot permanently starve this keeper's queue: [handle_turn] normally
   blocks until the turn's terminal status is observed (see
   [Server_routes_http_keeper_stream.process_single_turn]), and if the
   underlying async execution is cancelled mid-turn by its own internal
   timeout, nothing ever wakes that wait. [dispatch_deadline_sec] is set well
   above that internal timeout (see the .mli) so by the time it fires here,
   the turn's own machinery has already given up. *)
let run_leased_turn ~sw ~clock ~dispatch_deadline_sec ~handle_turn ~on_stalled ~keeper_name
    ~lease_id ~queued =
  match
    Eio.Fiber.first
      (fun () ->
        handle_turn ~sw ~keeper_name ~queued_message:queued;
        `Completed)
      (fun () ->
        Eio.Time.sleep clock dispatch_deadline_sec;
        `Stalled)
  with
  | `Completed -> ack_or_warn ~keeper_name ~lease_id
  | `Stalled -> (
      match on_stalled ~keeper_name ~queued_message:queued with
      | () -> ack_or_warn ~keeper_name ~lease_id
      | exception (Eio.Cancel.Cancelled _ as e) -> raise e
      | exception exn ->
          Log.Keeper.warn
            "keeper_chat_consumer: on_stalled failed for keeper=%s: %s; nacking \
             instead of acking so the batch is retried"
            keeper_name
            (Printexc.to_string exn);
          nack_or_warn ~keeper_name ~lease_id)

let dispatch_queued_turn state ~sw ~clock ~dispatch_deadline_sec ~handle_turn ~on_stalled
    ~keeper_name ~lease_id ~queued =
  Eio.Fiber.fork ~sw (fun () ->
      try
        run_leased_turn ~sw ~clock ~dispatch_deadline_sec ~handle_turn ~on_stalled
          ~keeper_name ~lease_id ~queued;
        clear_dispatching state keeper_name
      with
      | Eio.Cancel.Cancelled _ as e ->
          Eio.Cancel.protect (fun () -> nack_or_warn ~keeper_name ~lease_id);
          clear_dispatching state keeper_name;
          raise e
      | exn ->
          nack_or_warn ~keeper_name ~lease_id;
          clear_dispatching state keeper_name;
          Log.Keeper.warn
            "keeper_chat_consumer: handle_turn failed for keeper=%s: %s"
            keeper_name
            (Printexc.to_string exn))

let start ~sw ~clock ~base_path ~dispatch_deadline_sec ~handle_turn ~on_stalled =
  let dispatch_state = create_dispatch_state () in
  let rec poll_loop () =
    let keeper_names = Keeper_chat_queue.all_keeper_names () in
    List.iter
      (fun keeper_name ->
         (* While a turn is in flight, leave queued messages in place so
            everything sent during the turn coalesces into ONE follow-up
            turn instead of one turn per message — the keeper then answers
            with the full accumulated context (RFC-0225 single-flight
            makes the in-flight state observable). *)
         if is_dispatching dispatch_state keeper_name
         then ()
         else
           match Keeper_turn_admission.in_flight ~base_path ~keeper_name with
           | Some _ -> ()
           | None -> (
               if mark_dispatching dispatch_state keeper_name
               then (
                 let leased =
                   try Keeper_chat_queue.lease_batch ~keeper_name with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                       Log.Keeper.error
                         "keeper_chat_consumer: lease_batch raised for keeper=%s: %s \
                          (typed API contract violation — skipping this tick)"
                         keeper_name
                         (Printexc.to_string exn);
                       `Empty
                 in
                 match leased with
                 | `Empty -> clear_dispatching dispatch_state keeper_name
                 | `Already_leased lease_id ->
                     Log.Keeper.warn
                       "keeper_chat_consumer: lease_batch found an already-outstanding \
                        lease=%s for keeper=%s while this consumer holds the dispatch \
                        gate; leaving it for the next poll"
                       lease_id
                       keeper_name;
                     clear_dispatching dispatch_state keeper_name
                 | `Persist_failed msg ->
                     Log.Keeper.warn
                       "keeper_chat_consumer: lease_batch persist failed for keeper=%s: \
                        %s; retrying next poll"
                       keeper_name
                       msg;
                     clear_dispatching dispatch_state keeper_name
                 | `Leased { Keeper_chat_queue.lease_id; messages } ->
                     broadcast_queue_changed ~keeper_name;
                     (match messages with
                      | _ :: _ :: _ ->
                          Log.Keeper.info
                            "keeper_chat_consumer: coalesced %d queued messages \
                             into one turn for keeper=%s"
                            (List.length messages)
                            keeper_name
                      | [] | [ _ ] -> ());
                     (match Keeper_chat_queue.merge_batch messages with
                      | None ->
                          (* Unreachable in practice: [lease_batch] only returns
                             [`Leased] with a non-empty [messages]. Nack rather
                             than silently drop, and let the log carry the
                             invariant violation for triage. *)
                          Log.Keeper.error
                            "keeper_chat_consumer: lease=%s for keeper=%s carried \
                             zero messages; nacking"
                            lease_id
                            keeper_name;
                          nack_or_warn ~keeper_name ~lease_id;
                          clear_dispatching dispatch_state keeper_name
                      | Some queued ->
                          (try
                             dispatch_queued_turn dispatch_state ~sw ~clock
                               ~dispatch_deadline_sec ~handle_turn ~on_stalled
                               ~keeper_name ~lease_id ~queued
                           with
                           | Eio.Cancel.Cancelled _ as e ->
                               Eio.Cancel.protect (fun () ->
                                   nack_or_warn ~keeper_name ~lease_id);
                               clear_dispatching dispatch_state keeper_name;
                               raise e
                           | exn ->
                               nack_or_warn ~keeper_name ~lease_id;
                               clear_dispatching dispatch_state keeper_name;
                               Log.Keeper.warn
                                 "keeper_chat_consumer: dispatch fork failed for \
                                  keeper=%s: %s"
                                 keeper_name
                                 (Printexc.to_string exn))))
               else
                 Log.Keeper.warn
                   "keeper_chat_consumer: duplicate dispatch suppressed for \
                    keeper=%s"
                   keeper_name))
      keeper_names;
    Eio.Time.sleep clock poll_interval_sec;
    poll_loop ()
  in
  Eio.Fiber.fork ~sw poll_loop
