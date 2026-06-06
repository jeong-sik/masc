(** Keeper_chat_consumer — standalone polling fiber for queue drain. *)

let poll_interval_sec =
  match Sys.getenv_opt "MASC_KEEPER_QUEUE_POLL_SEC" with
  | Some s -> (
      try float_of_string s with Failure _ -> 1.0)
  | None -> 1.0

let start ~sw ~clock ~handle_turn =
  let rec poll_loop () =
    let keeper_names = Keeper_chat_queue.all_keeper_names () in
    List.iter
      (fun keeper_name ->
         match Keeper_chat_queue.dequeue ~keeper_name with
         | None -> ()
         | Some queued ->
             (try handle_turn ~keeper_name ~queued_message:queued with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                  Log.Keeper.warn
                    "keeper_chat_consumer: handle_turn failed for keeper=%s: %s"
                    keeper_name
                    (Printexc.to_string exn)))
      keeper_names;
    Eio.Time.sleep clock poll_interval_sec;
    poll_loop ()
  in
  Eio.Fiber.fork ~sw poll_loop
