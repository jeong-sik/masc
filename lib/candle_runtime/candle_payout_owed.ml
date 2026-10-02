(* See candle_payout_owed.mli. *)

let ( let* ) = Result.bind

let row ~at ~(goal : Goal_store.goal) ~(verdict : Goal_verification.verdict)
  ~(confirmation : Goal_verification.confirmation) ~passed_at =
  let* confirmed_at =
    Candle_stamp.copied ~what:"the confirmation's confirmed_at" confirmation.confirmed_at
  in
  Ok
    { Candle_event.at
    ; body =
        Candle_event.Payout_owed
          { goal_id = goal.id; request_id = verdict.request_id
          ; verification_run_id = verdict.verification_run_id; passed_at; confirmed_at }
    }
;;

let write ~now (config : Workspace_utils_backend_setup.config) goal verdict confirmation =
  Result.map_error
    (Candle_ledger.update_error_to_string Fun.id)
    (Candle_ledger.update ~base_path:config.base_path (fun view ->
       match
         Candle_payout.owed_pass
           ~goal_id:goal.Goal_store.id
           ~request_id:verdict.Goal_verification.request_id
           ~verification_run_id:verdict.verification_run_id
           ~passed_at:verdict.recorded_at
           (Candle_ledger.events view)
       with
       | None -> Ok ([], false)
       | Some passed_at ->
         let* at = Candle_stamp.at ~now in
         let* owed = row ~at ~goal ~verdict ~confirmation ~passed_at in
         Ok ([ owed ], true)))
;;

let record ~now (config : Workspace_utils_backend_setup.config) goal verdict confirmation =
  match Candle_status.for_recording ~base_path:config.base_path with
  | Candle_config.Off -> Ok ()
  | Candle_config.Disabled { reason } ->
    Log.Misc.warn
      "candle: no payout owed for goal_id=%s request_id=%s because candle is disabled: %s"
      goal.Goal_store.id
      verdict.Goal_verification.request_id
      reason;
    Ok ()
  | Candle_config.Enabled _ ->
    (match
       Result.map_error
         (fun detail -> "candle payout owed: " ^ detail)
         (write ~now config goal verdict confirmation)
     with
     | Ok wrote ->
       (* The worker takes it from here; it does not need the Goal's lock. *)
       if wrote then Candle_payout_worker.wake ();
       Ok ()
     | Error _ as refused -> refused)
;;

let after_confirmation config goal verdict confirmation =
  record ~now:Time_compat.now config goal verdict confirmation
;;
