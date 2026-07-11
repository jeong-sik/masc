(** Keeper_chat_consumer — standalone polling fiber for queue drain. *)

let poll_interval_sec =
  match Sys.getenv_opt "MASC_KEEPER_QUEUE_POLL_SEC" with
  | Some s -> (
      try float_of_string s with Failure _ -> 1.0)
  | None -> 1.0

type turn_outcome =
  | Delivered of { outcome_ref : string option }
  | Failed of
      { kind : Keeper_chat_queue.failure_kind
      ; detail : string
      ; outcome_ref : string option
      }

type lease_finalization =
  | Finalize of Keeper_chat_queue.finalization
  | Nack

type dispatch_state = {
  mutex : Eio.Mutex.t;
  running_by_keeper : (string, unit) Hashtbl.t;
  pending_finalizations : (string, string * lease_finalization) Hashtbl.t;
}

let create_dispatch_state () =
  { mutex = Eio.Mutex.create ()
  ; running_by_keeper = Hashtbl.create 16
  ; pending_finalizations = Hashtbl.create 16
  }

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

let pending_finalization state keeper_name =
  with_dispatch_state state (fun () ->
      Hashtbl.find_opt state.pending_finalizations keeper_name)

let clear_pending_finalization state ~keeper_name ~lease_id =
  with_dispatch_state state (fun () ->
      match Hashtbl.find_opt state.pending_finalizations keeper_name with
      | Some (pending_lease_id, _)
        when String.equal pending_lease_id lease_id ->
        Hashtbl.remove state.pending_finalizations keeper_name
      | Some _ | None -> ())

let remember_pending_finalization state ~keeper_name ~lease_id ~action =
  with_dispatch_state state (fun () ->
      Hashtbl.replace state.pending_finalizations keeper_name (lease_id, action))

module For_testing = struct
  type nonrec dispatch_state = dispatch_state

  let create_dispatch_state = create_dispatch_state
  let is_dispatching = is_dispatching
  let mark_dispatching = mark_dispatching
  let clear_dispatching = clear_dispatching
end

(* A finalization persist failure is recoverable: queue-core keeps the lease
   unchanged. Retain the exact typed decision and retry it before dispatching
   another turn for this Keeper. *)
let settle_lease state ~keeper_name ~lease_id action =
  let result =
    match action with
    | Finalize outcome ->
      (match Keeper_chat_queue.finalize ~keeper_name ~lease_id ~outcome with
       | `Finalized _ ->
         clear_pending_finalization state ~keeper_name ~lease_id;
         `Settled
       | `Unknown_lease ->
         clear_pending_finalization state ~keeper_name ~lease_id;
         Log.Keeper.warn
           "keeper_chat_consumer: finalize found no matching lease=%s for \
            keeper=%s (already finalized/nacked?)"
           lease_id
           keeper_name;
         `Settled
       | `Error error ->
         remember_pending_finalization state ~keeper_name ~lease_id ~action;
         Log.Keeper.error
           "keeper_chat_consumer: finalize persist failed for keeper=%s \
            lease=%s: %s; finalization will retry"
           keeper_name
           lease_id
           (Keeper_chat_queue.mutation_error_to_string error);
         `Pending)
    | Nack ->
      (match Keeper_chat_queue.nack ~keeper_name ~lease_id with
       | `Requeued _ ->
         clear_pending_finalization state ~keeper_name ~lease_id;
         `Settled
       | `Unknown_lease ->
         clear_pending_finalization state ~keeper_name ~lease_id;
         Log.Keeper.warn
           "keeper_chat_consumer: nack found no matching lease=%s for keeper=%s \
            (already acked/nacked?)"
           lease_id
           keeper_name;
         `Settled
       | `Error error ->
         remember_pending_finalization state ~keeper_name ~lease_id ~action;
         Log.Keeper.error
           "keeper_chat_consumer: nack persist failed for keeper=%s lease=%s: %s; \
            finalization will retry"
           keeper_name
           lease_id
           (Keeper_chat_queue.mutation_error_to_string error);
         `Pending)
  in
  result

(* Keep these names at the call sites readable: they now retain the decision
   when persistence is temporarily unavailable instead of silently giving up. *)
let finalize_or_warn state ~keeper_name ~lease_id outcome =
  match settle_lease state ~keeper_name ~lease_id (Finalize outcome) with
  | `Settled | `Pending -> ()

let nack_or_warn state ~keeper_name ~lease_id =
  match settle_lease state ~keeper_name ~lease_id Nack with
  | `Settled | `Pending -> ()

(* Kept as a separate helper so the poll loop cannot accidentally start a new
   turn while an earlier turn's durable ack/nack is still unresolved. *)
let retry_pending_finalization state ~keeper_name =
  match pending_finalization state keeper_name with
  | None -> false
  | Some (lease_id, action) ->
    (match settle_lease state ~keeper_name ~lease_id action with
    | `Settled | `Pending -> ());
    true

let finalization_of_turn_outcome ~clock = function
  | Delivered { outcome_ref } ->
      Keeper_chat_queue.Mark_delivered
        { completed_at = Eio.Time.now clock; outcome_ref }
  | Failed { kind; detail; outcome_ref } ->
      Keeper_chat_queue.Mark_failed
        { completed_at = Eio.Time.now clock
        ; kind
        ; detail
        ; outcome_ref
        }

let run_leased_turn state ~sw ~clock ~handle_turn ~keeper_name ~lease_id ~queued =
  match handle_turn ~sw ~keeper_name ~queued_message:queued with
  | outcome ->
      finalize_or_warn state ~keeper_name ~lease_id
        (finalization_of_turn_outcome ~clock outcome)
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
      let detail = Printexc.to_string exn in
      Log.Keeper.error
        "keeper_chat_consumer: handle_turn raised for keeper=%s: %s; recording \
         a terminal internal_error receipt"
        keeper_name detail;
      finalize_or_warn state ~keeper_name ~lease_id
        (Keeper_chat_queue.Mark_failed
           { completed_at = Eio.Time.now clock
           ; kind = Keeper_chat_queue.Internal_error
           ; detail
           ; outcome_ref = None
           })

let dispatch_queued_turn state ~sw ~clock ~handle_turn ~keeper_name ~lease_id
    ~queued =
  Eio.Fiber.fork ~sw (fun () ->
      try
        run_leased_turn state ~sw ~clock ~handle_turn ~keeper_name ~lease_id
          ~queued;
        clear_dispatching state keeper_name
      with
      | Eio.Cancel.Cancelled _ as e ->
          Eio.Cancel.protect (fun () -> nack_or_warn state ~keeper_name ~lease_id);
          clear_dispatching state keeper_name;
          raise e
      | exn ->
          nack_or_warn state ~keeper_name ~lease_id;
          clear_dispatching state keeper_name;
          Log.Keeper.error
            "keeper_chat_consumer: dispatch finalization failed unexpectedly \
             for keeper=%s: %s"
            keeper_name
            (Printexc.to_string exn))

let start ~sw ~clock ~base_path ~handle_turn =
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
           match retry_pending_finalization dispatch_state ~keeper_name with
           | true -> ()
           | false -> (
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
                 | `Error error ->
                     Log.Keeper.warn
                       "keeper_chat_consumer: lease_batch persist failed for keeper=%s: \
                        %s; retrying next poll"
                       keeper_name
                       (Keeper_chat_queue.mutation_error_to_string error);
                     clear_dispatching dispatch_state keeper_name
                 | `Leased { Keeper_chat_queue.lease_id; items } ->
                     (match items with
                      | _ :: _ :: _ ->
                          Log.Keeper.info
                            "keeper_chat_consumer: coalesced %d queued messages \
                             into one turn for keeper=%s"
                            (List.length items)
                            keeper_name
                      | [] | [ _ ] -> ());
                     (match Keeper_chat_queue.merge_batch items with
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
                          nack_or_warn dispatch_state ~keeper_name ~lease_id;
                          clear_dispatching dispatch_state keeper_name
                      | Some queued ->
                          (try
                             dispatch_queued_turn dispatch_state ~sw ~clock
                               ~handle_turn ~keeper_name ~lease_id ~queued
                           with
                           | Eio.Cancel.Cancelled _ as e ->
                               Eio.Cancel.protect (fun () ->
                                   nack_or_warn dispatch_state ~keeper_name ~lease_id);
                               clear_dispatching dispatch_state keeper_name;
                               raise e
                           | exn ->
                               nack_or_warn dispatch_state ~keeper_name ~lease_id;
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
                   keeper_name)))
      keeper_names;
    Eio.Time.sleep clock poll_interval_sec;
    poll_loop ()
  in
  Eio.Fiber.fork ~sw poll_loop
