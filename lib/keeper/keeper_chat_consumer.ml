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

let dispatch_queued_turn state ~sw ~handle_turn ~keeper_name ~queued =
  Eio.Fiber.fork ~sw (fun () ->
      try
        handle_turn ~sw ~keeper_name ~queued_message:queued;
        clear_dispatching state keeper_name
      with
      | Eio.Cancel.Cancelled _ as e ->
          clear_dispatching state keeper_name;
          raise e
      | exn ->
          clear_dispatching state keeper_name;
          Log.Keeper.warn
            "keeper_chat_consumer: handle_turn failed for keeper=%s: %s"
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
           match Keeper_turn_admission.in_flight ~base_path ~keeper_name with
           | Some _ -> ()
           | None -> (
               if mark_dispatching dispatch_state keeper_name
               then (
                 let batch =
                   try Keeper_chat_queue.dequeue_batch ~keeper_name with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn ->
                       Log.Keeper.warn
                         "keeper_chat_consumer: dequeue_batch failed for \
                          keeper=%s: %s"
                         keeper_name
                         (Printexc.to_string exn);
                       []
                 in
                 (match batch with
                  | _ :: _ :: _ ->
                      Log.Keeper.info
                        "keeper_chat_consumer: coalesced %d queued messages \
                         into one turn for keeper=%s"
                        (List.length batch)
                        keeper_name
                  | [] | [ _ ] -> ());
                 match Keeper_chat_queue.merge_batch batch with
                 | None -> clear_dispatching dispatch_state keeper_name
                 | Some queued ->
                     (try
                        dispatch_queued_turn dispatch_state ~sw ~handle_turn
                          ~keeper_name ~queued
                      with
                      | Eio.Cancel.Cancelled _ as e ->
                          clear_dispatching dispatch_state keeper_name;
                          raise e
                      | exn ->
                          clear_dispatching dispatch_state keeper_name;
                          Log.Keeper.warn
                            "keeper_chat_consumer: dispatch fork failed for \
                             keeper=%s: %s"
                            keeper_name
                            (Printexc.to_string exn)))
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
