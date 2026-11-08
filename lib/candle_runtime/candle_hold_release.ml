(* See candle_hold_release.mli. *)

open Result.Syntax

type outcome =
  | Released of { goal_id : string }
  | Not_waiting of { goal_id : string }
  | Not_held of { goal_id : string }
  | Unknown_goal of { goal_id : string }
  | Superseded of { goal_id : string }

type written = Written | Not_written
type decision = Release of Candle_payout.waiting | Refuse of outcome

(* The release row must still name the payout that is open and holding when
   the append runs. The Tasks were not read, so the only race is the ledger
   itself moving on. *)
let still_needed (w : Candle_payout.waiting) events =
  match Candle_payout.state ~goal_id:w.goal_id events with
  | Candle_payout.Waiting open_payout when open_payout = w ->
    Option.is_some (Candle_payout.held_window_of open_payout events)
  | Candle_payout.Waiting _ | Candle_payout.No_obligation | Candle_payout.Failed _
  | Candle_payout.Settled -> false
;;

let release ~now ~(config : Workspace_utils_backend_setup.config) ~goal_id =
  let base_path = config.Workspace_utils_backend_setup.base_path in
  match Candle_status.for_recording ~base_path with
  | Candle_status.Recording_off | Candle_status.Recording_disabled _
  | Candle_status.Recording_unavailable _ ->
    Error "candle is not recording"
  | Candle_status.Recording_enabled _ ->
    let* view = Result.map_error Candle_ledger.read_error_to_string (Candle_ledger.read ~base_path) in
    let events = Candle_ledger.events view in
    let waiting =
      List.find_opt
        (fun (w : Candle_payout.waiting) -> String.equal w.goal_id goal_id)
        (Candle_payout.waiting events) in
    let decision = match waiting with
      | Some w when Option.is_some (Candle_payout.held_window_of w events) -> Release w
      | Some _ -> Refuse (Not_held { goal_id })
      | None ->
        (match Candle_payout.state ~goal_id events with
         | Candle_payout.Settled | Candle_payout.Failed _ -> Refuse (Not_waiting { goal_id })
         | Candle_payout.No_obligation | Candle_payout.Waiting _ -> Refuse (Unknown_goal { goal_id }))
    in
    match decision with
    | Refuse outcome -> Ok outcome
    | Release w ->
      let* at = Candle_stamp.at ~now in
      let row = {Candle_event.at; body = Candle_event.Candidate_window_released
          {goal_id = w.goal_id; request_id = w.request_id;
           verification_run_id = w.verification_run_id}} in
      let* attempt = Result.map_error
        (Candle_ledger.update_error_to_string Fun.id)
        (Candle_ledger.update_once ~base_path (fun view ->
           let events = Candle_ledger.events view in
           if still_needed w events then Ok ([row], Written) else Ok ([], Not_written))) in
      let written = match attempt with
        | Candle_ledger.Updated result -> result
        | Candle_ledger.Changed -> Not_written in
      Ok (match written with
        | Written -> Released { goal_id }
        | Not_written -> Superseded { goal_id })
;;
