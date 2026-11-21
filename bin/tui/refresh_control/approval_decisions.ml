module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Approvals_asks_settlement = Masc_tui_refresh_settlement.Approvals_asks_settlement
module Approval = Masc_tui_operator_projection
module Ask = Masc_tui_ask_projection

let approval_decision_key = function
  | Approval.Confirm -> "y"
  | Approval.Deny -> "n"

let approval_decision_done = function
  | Approval.Confirm -> "Confirmed"
  | Approval.Deny -> "Denied"

let approval_decision_unverified = function
  | Approval.Confirm -> "Confirmation outcome unverified"
  | Approval.Deny -> "Denial outcome unverified"


let apply_approval_decision_result (state : T.state) approval decision approvals result =
  (match state.T.home_decision_inflight with
   | Some (T.Home_operator_request token as request) when token = approval.Approval.ap_token ->
       let receipt = match result with
         | Ok (Approval.Completed _) -> approval_decision_done decision ^ ": " ^ approval.Approval.ap_summary
         | Ok (Approval.Deferred _) -> "Confirmation accepted; action deferred: " ^ approval.Approval.ap_summary
         | Ok (Approval.Execution_failed (_, detail)) -> "Confirmation accepted; action failed: " ^ approval.Approval.ap_summary ^ " · " ^ detail
         | Error (T.Request_failed error) -> approval_decision_unverified decision ^ ": " ^ approval.Approval.ap_summary ^ " · " ^ error
         | Error (T.Request_withdrawn refusal) ->
             T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
               ~request:T.Kept_request.Approval_decision refusal
             ^ " · " ^ approval.Approval.ap_summary
       in
       state.T.home_decision_receipt <- Some (request, receipt)
   | Some (T.Home_held_call _ | T.Home_gate_request _ | T.Home_operator_request _
          | T.Home_question _ | T.Home_goal_confirmation _)
   | None -> ());
  state.T.home_decision_inflight <- None;
  (match result with
   | Ok (Approval.Completed _) ->
       Masc_tui_loader.report_action state "system"
         (Printf.sprintf "%s: %s" (approval_decision_done decision)
            approval.Approval.ap_summary)
   | Ok (Approval.Deferred _) ->
       Masc_tui_loader.report_action state "system"
         (Printf.sprintf "Confirmation accepted; action deferred: %s"
            approval.Approval.ap_summary)
   | Ok (Approval.Execution_failed (_, detail)) ->
       Masc_tui_loader.report_action state "error"
         (Printf.sprintf "Confirmation accepted; action failed: %s" detail)
   | Error (T.Request_failed err) ->
       Masc_tui_loader.report_action state "error"
         (Printf.sprintf "%s: %s" (approval_decision_unverified decision) err)
   | Error (T.Request_withdrawn refusal) ->
       Request_notice.report_withdrawn state ~request:T.Kept_request.Approval_decision refusal);
  Approvals_asks_settlement.apply_approvals_load state (Result.map_error (fun detail -> T.Request_failed detail) approvals)

let apply_approval_decision_completion (state : T.state) generation approval decision result
    approvals =
  state.T.pending_approval_action <- None;
  let flow, owns_action =
    Approval.Flow.finish_action state.T.approval_flow generation
  in
  state.T.approval_flow <- flow;
  if owns_action then
    apply_approval_decision_result state approval decision approvals result

let start_approval_decision (state : T.state) approval decision ~mailbox =
  let enqueue_async = Admission.workspace_enqueue state in
  let authority = state.T.workspace_authority in
  let identity = state.T.server_identity in
  let reading = Some state.T.workspace_read_authority in
  if state.T.workspace_identity <> T.Workspace_identity_match then
    Request_notice.report_kept_back state ~request:T.Kept_request.Approval_decision T.workspace_identity_unconfirmed T.Nothing_kept
  else
  match Approval.Flow.begin_action state.T.approval_flow with
  | Error `Already_inflight ->
      state.T.pending_approval_action <- None;
      Masc_tui_loader.report_action state "system" "Approval action already in progress"
  | Ok (flow, generation) ->
    let () = state.T.approval_flow <- flow in
    let () = state.T.pending_approval_action <- None in
    Masc_tui_work_requests.Approval_gate_requests.supersede_home_decision_receipt state;
    state.T.home_decision_inflight <- state.T.home_opened_request;
    let host = Admission.server_peer_host in
    let port = state.T.port in
    let confirm () =
      match Admission.admit_request state ~mailbox ~authority ~identity ~host ~port () with
      | Error refusal -> Error (T.Request_withdrawn refusal)
      | Ok () ->
        Result.map_error (fun detail -> T.Request_failed detail)
          (Masc_tui_http.post_operator_confirm ~host ~port
             ~token:approval.Approval.ap_token ~decision)
    in
    let reload () =
      if T.workspace_reply_admitted state ~authority ~reading ~kind:T.Workspace_observation
      then Masc_tui_loader.load_approvals ~host ~port
      else Error "Approval result retained; workspace identity is unconfirmed"
    in
    let run_action () =
      let result =
        try
          confirm ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (T.Request_failed (Printexc.to_string exn))
      in
      let approvals =
        try
          reload () with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error ("approvals reload failed: " ^ Printexc.to_string exn)
      in
      enqueue_async mailbox
        (P.Approvals_msg (P.Approval_decision_done (approval, decision, result, generation, approvals)))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Admission.fork_job state ~mailbox ~sw run_action
    | None ->
        let result =
          try
            confirm ()
          with exn -> Error (T.Request_failed (Printexc.to_string exn))
        in
        let approvals =
          try
          reload () with
          | exn -> Error ("approvals reload failed: " ^ Printexc.to_string exn)
        in
        let result, approvals = T.workspace_operation_reply state ~authority ~reading (result, approvals) in
        apply_approval_decision_completion state generation approval decision
          result approvals

(* TEL-OK: TUI-local confirmation gate emits user-visible events here; the
   operator confirmation endpoint owns durable approval telemetry. *)
let handle_approval_decision (state : T.state) approval decision ~mailbox =
  match
    Approval.approval_gate_transition
      ~inflight:(Approval.Flow.action_inflight state.T.approval_flow)
      ~pending:state.T.pending_approval_action ~token:approval.Approval.ap_token ~decision
  with
  | Approval.Gate_blocked_inflight ->
      state.T.pending_approval_action <- None;
      Masc_tui_loader.report_action state "system" "Approval action already in progress"
  | Approval.Gate_submit ->
      start_approval_decision state approval decision ~mailbox
  | Approval.Gate_arm pending ->
      state.T.pending_approval_action <- Some pending;
      Masc_tui_loader.report_action state "system"
        (Printf.sprintf "Press %s again: %s"
           (approval_decision_key decision)
           approval.Approval.ap_summary)

let toggle_selected_ask_origin (state : T.state) =
  match T.current_ask_origin state with
  | Some _ -> state.T.ask_origin <- None
  | None ->
      let origin = T.selected_ask_origin state in
      (match origin with
       | None -> Masc_tui_loader.report_action state "system" "No Keeper turn asked this question"
       | Some origin ->
           T.toggle_ask_origin state origin;
           state.T.ask_question_scroll <- 0;
           Option.iter (fun origin ->
             Log.Transport.info "tui_ask_source=%s"
               (Yojson.Safe.to_string (`Assoc
                 ["opened_ns",`String (Int64.to_string (Mtime_clock.elapsed_ns ()));
                  "origin",Ask.origin_to_json origin]))) (T.current_ask_origin state))

(* A server action belongs to the Keeper that submitted it even when its
   completion arrives after navigation. Keep offscreen outcomes in the action
   record; they cannot replace the selected Keeper's notice. *)
let present_identity_notice (state : T.state) ~keeper_name (kind, text) =
  match keeper_name with
  | Some name when T.keeper_detail_target_matches state name ->
      state.T.identity_attempt_error <- Some (kind, text)
  | Some name -> Masc_tui_loader.report_action state "system" (name ^ ": " ^ text)
  | None -> Masc_tui_loader.report_action state "system" text
