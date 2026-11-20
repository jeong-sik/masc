module T = Masc_tui_types
module P = Masc_tui_async_protocol
module W = Masc_tui_words
module WA = Masc_tui_transport.Workspace_admission
module RN = Masc_tui_transport.Request_notice
module Approval = Masc_tui_operator_projection
module Keeper_chat = Masc_tui_keeper_chat_projection

(* Answer the call the keeper is held at. Runs on its own fiber: the pane stays
   responsive, and a slow server costs the answer rather than the keypress. *)
(* Only an actual dispatch supersedes the preceding receipt; a late operator
   completion cannot restore ownership after another decision starts. *)
let supersede_home_decision_receipt (state : T.state) =
  state.home_decision_receipt <- None;
  state.home_decision_inflight <- None

let catch_non_cancel f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (T.Request_failed (Printexc.to_string exn))

let with_confirmed_workspace (state : T.state) ~request k =
  if state.workspace_identity <> T.Workspace_identity_match then
    RN.report_kept_back state ~request W.workspace_identity_unconfirmed
      W.Nothing_kept
  else
    match state.server_identity with
    | None ->
        RN.report_kept_back state ~request W.workspace_identity_unread
          W.Nothing_kept
    | Some expected_workspace -> k expected_workspace

let launch_approval_job (state : T.state) ~mailbox ~deliver f =
  let enqueue_async = WA.workspace_enqueue state in
  let run () =
    let result = catch_non_cancel f in
    enqueue_async mailbox (deliver result)
  in
  match Eio_context.get_switch_opt () with
  | Some sw -> WA.fork_job state ~mailbox ~sw run
  | None ->
      enqueue_async mailbox
        (deliver (Error (T.Request_failed "Eio switch is unavailable")))

let post_keeper_tool_approval_checked (state : T.state) ~authority ~host ~port
    ~expected_workspace ~keeper_name ~tool_call_id ~approval_id ~allow () =
  let open Result.Syntax in
  let failed result = Result.map_error (fun detail -> T.Request_failed detail) result in
  let* () =
    if authority <> state.workspace_authority then
      Error (T.Request_withdrawn T.Workspace_authority_withdrawn)
    else Ok ()
  in
  let* () =
    failed (WA.probe_expected_workspace ~host ~port expected_workspace)
  in
  failed
    (Masc_tui_http.post_keeper_tool_approval ~expected_workspace ~host ~port
       ~keeper_name ~tool_call_id ~approval_id ~allow)

(* The Approvals-surface twin of [launch_keeper_approval]: same route, no chat
   request to correlate with, so the outcome lands in the session log instead
   of a pane's transcript. *)
let launch_surface_tool_approval (state : T.state) ~mailbox ~keeper_name
    ~tool_call_id ~approval_id ~allow =
  let authority = state.workspace_authority in
  with_confirmed_workspace state ~request:W.Kept_request.Tool_approval
    (fun expected_workspace ->
      (* Answering a held tool call mutates server state over one round trip, like
         the Gate and operator-confirm decisions beside it. Take the same
         single-action slot so the header shows [submitting] at once and a repeat
         press during the trip is refused rather than answering the call twice.
         Completion ([Keeper_tool_approval_answered]) releases the slot. *)
      match Approval.Flow.begin_action state.approval_flow with
      | Error `Already_inflight ->
          Masc_tui_loader.report_action state "system"
            "Approval action already in progress"
      | Ok (flow, generation) ->
          state.approval_flow <- flow;
          supersede_home_decision_receipt state;
          let host = WA.server_peer_host in
          let port = state.port in
          launch_approval_job state ~mailbox
            ~deliver:(fun result ->
              P.Keeper_msg
                (P.Keeper_tool_approval_answered
                   ( keeper_name
                   , tool_call_id
                   , approval_id
                   , allow
                   , result
                   , generation )))
            (post_keeper_tool_approval_checked state ~authority ~host ~port
               ~expected_workspace ~keeper_name ~tool_call_id ~approval_id
               ~allow))

(* Fetch the held tool calls for the Approvals surface. Its own fiber for the
   same reason every loader runs on one: a slow server costs the refresh, not
   the keypress. *)
let launch_keeper_tool_approvals_load ?(intent = T.Snapshot_read.Join)
    (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
    let enqueue_async = WA.workspace_enqueue state in
    if state.workspace_identity <> T.Workspace_identity_match then ()
    else
      match state.server_identity with
      | None -> ()
      | Some expected_workspace -> (
          let read, request =
            T.Snapshot_read.start ~intent state.keeper_tool_approvals_read
          in
          state.keeper_tool_approvals_read <- read;
          match request with
          | None -> ()
          | Some request ->
              (* As for the Gate: whatever started this read, it answers the changes
                 announced before it. *)
              state.held_calls_owed <-
                Masc_tui_owed_read.started state.held_calls_owed;
              let host = WA.server_peer_host in
              let port = state.port in
              WA.launch_async_read state ~mailbox
                ~deliver:(fun result ->
                  enqueue_async mailbox
                    (P.Keeper_msg
                       (P.Keeper_tool_approvals_loaded
                          (request, expected_workspace, result))))
                (fun () ->
                  let open Result.Syntax in
                  let* () =
                    WA.probe_expected_workspace ~host ~port expected_workspace
                  in
                  let* held =
                    Masc_tui_loader.load_keeper_tool_approvals ~host ~port
                  in
                  let* () =
                    WA.probe_expected_workspace ~host ~port expected_workspace
                  in
                  Ok held))
  end

(* Mutation receipts belong to the last confirmed workspace even while its
   health cannot be read. A named replacement never inherits those receipts. *)
let retains_receipt_workspace (state : T.state) expected_workspace =
  match state.workspace_identity with
  | T.Workspace_identity_match | T.Workspace_identity_match_unconfirmed _ ->
      Option.exists
        (WA.same_server_workspace expected_workspace)
        state.server_identity
  | T.Workspace_identity_unread | T.Workspace_identity_mismatch _ -> false

let launch_gate_snapshot_load ?(intent = T.Snapshot_read.Join)
    (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
    let enqueue_async = WA.workspace_enqueue state in
    if state.workspace_identity <> T.Workspace_identity_match then ()
    else
      match state.server_identity with
      | None -> ()
      | Some expected_workspace -> (
          let read, request =
            T.Snapshot_read.start ~intent state.gate_snapshot_read
          in
          state.gate_snapshot_read <- read;
          match request with
          | None -> ()
          | Some request ->
              (* A Gate read began, whatever started it: a change announced from now on
                 owes the one after it, and one announced before it is answered by it. *)
              state.gate_snapshot_owed <-
                Masc_tui_owed_read.started state.gate_snapshot_owed;
              let host = WA.server_peer_host in
              let port = state.port in
              Log.Transport.debug
                "started Gate snapshot request=%d intent=%s"
                (T.Snapshot_read.request_id request)
                (match intent with
                 | T.Snapshot_read.Join -> "join"
                 | T.Snapshot_read.Refresh -> "refresh");
              WA.launch_async_read state ~mailbox
                ~deliver:(fun result ->
                  enqueue_async mailbox
                    (P.Gate_msg
                       (P.Gate_snapshot_loaded
                          (request, expected_workspace, result))))
                (fun () ->
                  let open Result.Syntax in
                  let* () =
                    WA.probe_expected_workspace ~host ~port expected_workspace
                  in
                  let* snapshot =
                    Masc_tui_loader.load_dashboard_gate ~host ~port
                  in
                  let* () =
                    WA.probe_expected_workspace ~host ~port expected_workspace
                  in
                  Ok snapshot))
  end

(* [reason] mirrors [Masc_tui_http.post_dashboard_gate_resolve]: required
   labeled option, because a trailing [?reason] here is unerasable
   (warning 16). *)
let launch_gate_resolve (state : T.state) ~mailbox ~approval_id ~approve
    ~reason =
  let authority = state.workspace_authority in
  with_confirmed_workspace state ~request:W.Kept_request.Gate_decision
    (fun expected_workspace ->
      (* A Gate decision mutates durable server state over one round trip. Take the
         same single-action slot the operator-confirm path takes, so the header
         draws [submitting] the instant the key lands and a second press during the
         trip is refused here instead of firing a duplicate resolve. Completion
         ([Gate_approval_resolved]) releases the slot. *)
      match Approval.Flow.begin_action state.approval_flow with
      | Error `Already_inflight ->
          Masc_tui_loader.report_action state "system"
            "Approval action already in progress"
      | Ok (flow, generation) ->
          state.approval_flow <- flow;
          supersede_home_decision_receipt state;
          let host = WA.server_peer_host in
          let port = state.port in
          launch_approval_job state ~mailbox
            ~deliver:(fun result ->
              P.Gate_msg
                (P.Gate_approval_resolved
                   ( approval_id
                   , approve
                   , expected_workspace
                   , result
                   , generation )))
            (fun () ->
              let open Result.Syntax in
              let failed result =
                Result.map_error (fun detail -> T.Request_failed detail) result
              in
              let* () =
                if authority <> state.workspace_authority then
                  Error (T.Request_withdrawn T.Workspace_authority_withdrawn)
                else Ok ()
              in
              let* () =
                failed
                  (WA.probe_expected_workspace ~host ~port expected_workspace)
              in
              failed
                (Masc_tui_http.post_dashboard_gate_resolve ~host ~port
                   ~approval_id ~approve ~reason ~expected_workspace)))

let launch_gate_auto_judge_retry (state : T.state) ~mailbox
    (pending : Masc.Tui_decode.gate_pending) =
  let authority = state.workspace_authority in
  with_confirmed_workspace state ~request:W.Kept_request.Auto_judge_retry
    (fun expected_workspace ->
      match pending.Masc.Tui_decode.gp_retry_request with
      | None ->
          Masc_tui_loader.report_action state "system"
            "This Auto Judge result cannot be replayed safely; decide it with \
             y/n"
      | Some request -> (
          match Approval.Flow.begin_action state.approval_flow with
          | Error `Already_inflight ->
              Masc_tui_loader.report_action state "system"
                "Approval action already in progress"
          | Ok (flow, generation) ->
              state.approval_flow <- flow;
              supersede_home_decision_receipt state;
              let host = WA.server_peer_host in
              let port = state.port in
              launch_approval_job state ~mailbox
                ~deliver:(fun result ->
                  P.Gate_msg
                    (P.Gate_auto_judge_retried
                       ( pending.Masc.Tui_decode.gp_id
                       , expected_workspace
                       , result
                       , generation )))
                (fun () ->
                  let open Result.Syntax in
                  let failed result =
                    Result.map_error
                      (fun detail -> T.Request_failed detail)
                      result
                  in
                  let* () =
                    if authority <> state.workspace_authority then
                      Error
                        (T.Request_withdrawn T.Workspace_authority_withdrawn)
                    else Ok ()
                  in
                  let* () =
                    failed
                      (WA.probe_expected_workspace ~host ~port
                         expected_workspace)
                  in
                  failed
                    (Masc_tui_http.post_dashboard_gate_retry ~host ~port ~request
                       ~expected_workspace))))

let launch_gate_mode_set (state : T.state) ~mailbox ~lane ~mode =
  let authority = state.workspace_authority in
  match T.write_authority_refusal state authority with
  | Some refusal ->
      RN.report_withdrawn state ~request:W.Kept_request.Gate_mode_change refusal
  | None ->
      let host = WA.server_peer_host in
      let port = state.port in
      launch_approval_job state ~mailbox
        ~deliver:(fun result -> P.Gate_msg (P.Gate_mode_set (lane, mode, result)))
        (fun () ->
          match T.write_authority_refusal state authority with
          | Some refusal -> Error (T.Request_withdrawn refusal)
          | None ->
              Result.map_error
                (fun detail -> T.Request_failed detail)
                (match lane with
                 | Masc_tui_palette.Workspace_gate ->
                     Masc_tui_http.post_dashboard_gate_workspace_mode ~host
                       ~port ~mode
                 | Masc_tui_palette.External_gate ->
                     Masc_tui_http.post_dashboard_gate_external_mode ~host ~port
                       ~mode))

let launch_keeper_tool_modes_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then
    let authority = state.workspace_authority in
    (* Declines while the operator's own press is still in flight: the answer
       on the way back would be the stance from before it. This checks the
       press slot directly rather than reserving a shared refresh generation
       -- see [Keeper_tool_modes_loaded]'s doc comment for why sharing that
       counter with the background poll dropped answers no press ever
       raced (#37461). The generation observed here (not reserved: observing
       does not advance it) is carried to the arrival handler so a press that
       opens after this check but before the answer lands is still caught
       (#37609 review). *)
    if Approval.Flow.action_inflight state.approval_flow then ()
    else
      let order, ticket =
        Approval.Listing_order.dispatch state.tool_modes_order
          state.approval_flow
      in
      state.tool_modes_order <- order;
      let host = WA.server_peer_host in
      let port = state.port in
      launch_approval_job state ~mailbox
        ~deliver:(fun result ->
          P.Keeper_msg (P.Keeper_tool_modes_loaded (result, ticket)))
        (fun () ->
          match T.write_authority_refusal state authority with
          | Some refusal -> Error (T.Request_withdrawn refusal)
          | None ->
              Masc_tui_loader.load_keeper_tool_approval_modes ~host ~port
              |> Result.map_error (fun detail -> T.Request_failed detail))

let launch_keeper_tool_mode_set (state : T.state) ~mailbox ~keeper_name ~mode =
  let authority = state.workspace_authority in
  match T.write_authority_refusal state authority with
  | Some refusal ->
      RN.report_withdrawn state ~request:W.Kept_request.Tool_mode_change refusal
  | None -> (
      (* [begin_action] takes the newest generation, so a stance listing already
         on the wire stops being current and cannot put the old answer back on
         top of this press. It also refuses a second press while one is open. *)
      match Approval.Flow.begin_action state.approval_flow with
      | Error `Already_inflight ->
          Masc_tui_loader.report_action state "system"
            (Printf.sprintf "%s's gate is already changing; wait for the answer"
               keeper_name)
      | Ok (flow, generation) ->
          state.approval_flow <- flow;
          let host = WA.server_peer_host in
          let port = state.port in
          launch_approval_job state ~mailbox
            ~deliver:(fun result ->
              P.Keeper_msg
                (P.Keeper_tool_mode_set (keeper_name, mode, result, generation)))
            (fun () ->
              match T.write_authority_refusal state authority with
              | Some refusal -> Error (T.Request_withdrawn refusal)
              | None ->
                  Masc_tui_http.post_keeper_tool_approval_mode ~host ~port
                    ~keeper_name ~mode
                  |> Result.map_error (fun detail -> T.Request_failed detail)))

let launch_keeper_approval (state : T.state) ~mailbox
    (request : Keeper_chat.request) ~tool_call_id ~approval_id ~allow =
  let authority = state.workspace_authority in
  with_confirmed_workspace state ~request:W.Kept_request.Tool_approval
    (fun expected_workspace ->
      supersede_home_decision_receipt state;
      let host = WA.server_peer_host in
      let port = state.port in
      let keeper_name = request.Keeper_chat.keeper_name in
      launch_approval_job state ~mailbox
        ~deliver:(fun result ->
          P.Keeper_msg
            (P.Keeper_chat_approval_answered
               (request, tool_call_id, allow, result)))
        (post_keeper_tool_approval_checked state ~authority ~host ~port
           ~expected_workspace ~keeper_name ~tool_call_id ~approval_id ~allow))
