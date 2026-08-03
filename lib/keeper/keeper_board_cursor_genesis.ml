type error =
  | Shutdown_fenced of Keeper_shutdown_types.Operation_id.t
  | Lifecycle_reserved of Keeper_lifecycle_reservation.snapshot
  | Restore_failed of Keeper_reaction_ledger.board_cursor_restore_error
  | Persist_failed of string

let error_to_string = function
  | Shutdown_fenced operation_id ->
    Printf.sprintf
      "shutdown operation %s owns keeper admission"
      (Keeper_shutdown_types.Operation_id.to_string operation_id)
  | Lifecycle_reserved owner ->
    Keeper_lifecycle_reservation.snapshot_to_string owner
  | Restore_failed error ->
    Keeper_reaction_ledger.board_cursor_restore_error_to_string error
  | Persist_failed detail -> detail
;;

let ensure_with ?lifecycle_token ~current_post_cursor ~base_path ~keeper_name () =
  try
    Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name (fun () ->
      match
        Keeper_lifecycle_reservation.authorize
          ?token:lifecycle_token
          ~base_path
          ~keeper_name
          ()
      with
      | Error owner -> Error (Lifecycle_reserved owner)
      | Ok () ->
        (* The lifecycle key lock remains outside and before the admission
           lock. Board and JSONL operations may suspend, so the admission
           authority below uses its fiber-cooperative durable-effect slot. *)
        (match
           Keeper_turn_admission.run_durable_effect_if_open
             ~base_path
             ~keeper_name
             (fun _intake_token ->
                match
                  Keeper_reaction_ledger.latest_board_cursor_result
                    ~base_path
                    ~keeper_name
                with
                | Error error -> Error (Restore_failed error)
                | Ok (Some _) -> Ok ()
                | Ok None ->
                  let cursor_ts, post_id = current_post_cursor () in
                  Keeper_reaction_ledger.record_board_cursor_ack
                    ~base_path
                    ~keeper_name
                    ~cursor_ts
                    ~post_id
                    ();
                  Ok ())
         with
         | Keeper_turn_admission.Durable_effect_shutdown_reserved operation_id ->
           Error (Shutdown_fenced operation_id)
         | Keeper_turn_admission.Durable_effect_committed result -> result))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Persist_failed (Printexc.to_string exn))
;;

let ensure ?lifecycle_token ~base_path ~keeper_name () =
  ensure_with
    ?lifecycle_token
    ~current_post_cursor:Board_dispatch.current_post_cursor
    ~base_path
    ~keeper_name
    ()
;;
