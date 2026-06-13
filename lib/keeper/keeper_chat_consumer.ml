(** Keeper_chat_consumer — standalone polling fiber for queue drain. *)

let poll_interval_sec =
  match Sys.getenv_opt "MASC_KEEPER_QUEUE_POLL_SEC" with
  | Some s -> (
      try float_of_string s with Failure _ -> 1.0)
  | None -> 1.0

let start ~sw ~clock ~base_path ~handle_turn =
  let rec poll_loop () =
    let keeper_names = Keeper_chat_queue.all_keeper_names () in
    List.iter
      (fun keeper_name ->
         (* While a turn is in flight, leave queued messages in place so
            everything sent during the turn coalesces into ONE follow-up
            turn instead of one turn per message — the keeper then answers
            with the full accumulated context (RFC-0225 single-flight
            makes the in-flight state observable). *)
         match Keeper_turn_admission.in_flight ~base_path ~keeper_name with
         | Some _ -> ()
         | None -> (
             let batch = Keeper_chat_queue.dequeue_batch ~keeper_name in
             (match batch with
              | _ :: _ :: _ ->
                  Log.Keeper.info
                    "keeper_chat_consumer: coalesced %d queued messages into \
                     one turn for keeper=%s"
                    (List.length batch)
                    keeper_name
              | [] | [ _ ] -> ());
             match Keeper_chat_queue.merge_batch batch with
             | None -> ()
             | Some queued ->
                 (try handle_turn ~sw ~keeper_name ~queued_message:queued with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                      Log.Keeper.warn
                        "keeper_chat_consumer: handle_turn failed for keeper=%s: %s"
                        keeper_name
                        (Printexc.to_string exn))))
      keeper_names;
    Eio.Time.sleep clock poll_interval_sec;
    poll_loop ()
  in
  Eio.Fiber.fork ~sw poll_loop
