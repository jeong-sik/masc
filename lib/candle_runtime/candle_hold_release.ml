(* See candle_hold_release.mli. *)

open Result.Syntax

type outcome =
  | Released of { goal_id : string }
  | Not_waiting of { goal_id : string }
  | Not_held of { goal_id : string }
  | Unknown_goal of { goal_id : string }
  | Superseded of { goal_id : string }

type hold_identity =
  { request_id : string
  ; verification_run_id : string
  }

let release ~now ~(config : Workspace_utils_backend_setup.config) ~goal_id ~expected_hold =
  let base_path = config.Workspace_utils_backend_setup.base_path in
  match Candle_status.for_recording ~base_path with
  | Candle_status.Recording_off | Candle_status.Recording_disabled _
  | Candle_status.Recording_unavailable _ ->
    Error "candle is not recording"
  | Candle_status.Recording_enabled _ ->
    (* Re-evaluate against the latest ledger view on concurrent unrelated appends
       instead of aborting with a false [Superseded] outcome. *)
    Candle_ledger.update ~base_path (fun view ->
      let events = Candle_ledger.events view in
      let waiting =
        List.find_opt
          (fun (w : Candle_payout.waiting) -> String.equal w.goal_id goal_id)
          (Candle_payout.waiting events)
      in
      match waiting with
      | Some w when Option.exists (fun expected ->
          not (String.equal expected.request_id w.request_id
               && String.equal expected.verification_run_id w.verification_run_id)) expected_hold ->
        Ok ([], Superseded { goal_id })
      | Some w when Option.is_some (Candle_payout.held_window_of w events) ->
        let* at = Candle_stamp.at ~now in
        let row =
          { Candle_event.at
          ; body =
              Candle_event.Candidate_window_released
                { goal_id = w.goal_id
                ; request_id = w.request_id
                ; verification_run_id = w.verification_run_id
                }
          }
        in
        Ok ([ row ], Released { goal_id })
      | Some _ -> Ok ([], Not_held { goal_id })
      | None ->
        (match Candle_payout.state ~goal_id events with
         | Candle_payout.Settled | Candle_payout.Failed _ -> Ok ([], Not_waiting { goal_id })
         | Candle_payout.No_obligation | Candle_payout.Waiting _ -> Ok ([], Unknown_goal { goal_id })))
    |> Result.map_error (Candle_ledger.update_error_to_string Fun.id)
;;
