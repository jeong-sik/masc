module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Tui_decode = Masc.Tui_decode
module Inbox = Masc_tui_queue_inspection
module Keeper_control = Masc_tui_keeper_control
module Keeper_chat = Masc_tui_keeper_chat_projection
module Kept_request = Masc_tui_words.Kept_request

let settle_retired_queue_inspections (state : T.state) =
  let retired, current = List.partition
      (fun (_, reading) -> reading != state.T.workspace_read_authority)
      state.T.keeper_queue_inspections in
  state.T.keeper_queue_inspections <- current;
  List.iter (fun (keeper_name, _) ->
    let detail = Printf.sprintf "/queue for %s was interrupted by workspace reconnection; retry after reconnecting"
      keeper_name in
    match state.T.queue_panel with
    | Some panel when String.equal panel.T.qp_keeper keeper_name ->
      state.T.queue_panel <- Some {panel with T.qp_reading=T.Queue_unavailable;
        qp_notice=Some (T.Queue_error detail)}
    | Some _ | None -> Chat_notice.chat_notice state ~keeper_name:(Some keeper_name) ~kind:Chat_notice.Notice_failure detail) retired

let launch_keeper_queue (state : T.state) ~mailbox ~keeper_name (action : Inbox.action) =
  let panel_notice ~failure text =
    match action with
    | Inbox.Inspect_peers (token, _) ->
      ignore (T.stage_keeper_peer_reading state ~keeper_name ~token (Error (T.Request_failed text)))
    | Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
    | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
    | Inbox.Cancel_event _ | Inbox.Prioritize_event _ ->
      (match state.T.queue_panel with
       | Some panel when String.equal panel.T.qp_keeper keeper_name ->
         let outcome = if failure then T.Queue_error text else T.Queue_info text in
         state.T.queue_panel <- Some
           (if action = Inbox.Inspect then
              {panel with T.qp_reading=T.Queue_unavailable; qp_notice=Some outcome}
            else {panel with T.qp_reading=T.Queue_unavailable; qp_receipt=Some (T.Queue_action_receipt outcome)})
       | Some _ | None ->
         Chat_notice.chat_notice state ~keeper_name:(Some keeper_name)
           ~kind:(if failure then Chat_notice.Notice_failure else Chat_notice.Notice_reply) text) in
  if not (T.server_authority_ready state) then
    panel_notice ~failure:true (Masc_tui_transport.Request_notice.kept_back_until_reconnect ~ko:(state.T.ui_language = T.Lang_ko)
      ~request:(Kept_request.Command "/queue"))
  else begin
  let enqueue_async = Masc_tui_transport.Workspace_admission.workspace_enqueue state in
  let authority = state.T.workspace_authority in
  let reading = state.T.workspace_read_authority in
  let check_authority () =
    if authority = state.T.workspace_authority && T.server_authority_ready state
       && (match action with
           | Inbox.Inspect_peers (token, _) -> reading == state.T.workspace_read_authority
               && T.keeper_peer_read_current state ~keeper_name ~token
           | Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
           | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
           | Inbox.Cancel_event _ | Inbox.Prioritize_event _ -> true) then Ok ()
    else Error "Workspace changed; the remaining queue requests were not sent" in
  let get_json ~host ~port ~path =
    Result.bind (check_authority ()) (fun () -> Masc_tui_http.get_json ~host ~port ~path) in
  let post_json ~host ~port ~path ~body =
    Result.bind (check_authority ()) (fun () -> Masc_tui_http.post_json ~host ~port ~path ~body) in
  let priority_inflight = List.exists (fun (request : Keeper_chat.request) ->
    String.equal request.Keeper_chat.keeper_name keeper_name) state.T.keeper_run_next_inflight in
  if action = Inbox.Inspect && priority_inflight then
    (match state.T.queue_panel with
     | Some panel when String.equal panel.T.qp_keeper keeper_name ->
       state.T.queue_panel <- Some {panel with T.qp_reading=T.Queue_loading; qp_refresh_after_priority=true;
         qp_notice=Some (T.Queue_info "Waiting for the priority update before reading")}
     | Some _ | None -> ())
  else if (match action with Inbox.Run_next _ | Inbox.Move_to_end _ -> true
    | Inbox.Inspect | Inbox.Inspect_peers _ | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
    | Inbox.Edit _ | Inbox.Cancel_event _ | Inbox.Prioritize_event _ -> false)
    && Masc_tui_chat_dispatch.Queue_steer.run_next_busy_for state keeper_name then
    panel_notice ~failure:false "Another message priority change is pending; wait and refresh"
  else if (match action with Inbox.Inspect_peers _ -> false
      | Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
      | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
      | Inbox.Cancel_event _ | Inbox.Prioritize_event _ -> List.mem keeper_name state.T.keeper_queue_inflight) then
    (match state.T.queue_panel with
     | Some panel when String.equal panel.T.qp_keeper keeper_name ->
       state.T.queue_panel <- Some {panel with T.qp_reading=T.Queue_loading;
         qp_refresh_after_priority=(panel.T.qp_refresh_after_priority || action = Inbox.Inspect);
         qp_notice=Some (T.Queue_info "A queue request is already pending")}
     | Some _ | None -> panel_notice ~failure:false
         "A queue request is pending; wait for its result before the next change")
  else begin
  let local_resume = action = Inbox.Resume
    && state.T.workspace_identity = T.Workspace_identity_match
    && T.keeper_available_for_new_message state keeper_name
    && T.can_resume_preflight_keeper_input state keeper_name in
  let expected_workspace = state.T.server_identity in
  (match action with
   | Inbox.Inspect ->
       state.T.keeper_queue_inflight <- keeper_name :: state.T.keeper_queue_inflight;
       state.T.keeper_queue_readings <- keeper_name :: state.T.keeper_queue_readings;
       state.T.keeper_queue_inspections <-
         (keeper_name, state.T.workspace_read_authority)
         :: List.filter (fun (keeper, _) -> keeper <> keeper_name) state.T.keeper_queue_inspections
   | Inbox.Inspect_peers _ -> ()
   | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _ | Inbox.Move_to_end _
   | Inbox.Run_next _ | Inbox.Edit _ | Inbox.Cancel_event _ | Inbox.Prioritize_event _ ->
       state.T.keeper_queue_inflight <- keeper_name :: state.T.keeper_queue_inflight;
       state.T.keeper_queue_inspections <- List.filter
         (fun (keeper, _) -> keeper <> keeper_name) state.T.keeper_queue_inspections);
  let control_generation = match action with
    | Inbox.Pause | Inbox.Resume ->
        Some (T.begin_keeper_chat_control ~preserve_input_holds:local_resume
                ~preserve_priority_requests:local_resume state keeper_name)
    | Inbox.Inspect | Inbox.Inspect_peers _ | Inbox.Cancel _ | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit (_, _)
    | Inbox.Cancel_event (_, _, _) | Inbox.Prioritize_event (_, _, _)
    | Inbox.Clear -> None in
  let resume_input_ids = match action with
    | Inbox.Resume -> T.retained_keeper_input_ids state keeper_name
    | Inbox.Inspect | Inbox.Inspect_peers _ | Inbox.Pause | Inbox.Cancel _
    | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _ | Inbox.Cancel_event _
    | Inbox.Prioritize_event _ | Inbox.Clear -> [] in
  (* The lines /queue clear asks the server to cancel. Read here, on the fiber
     that owns [state]; the job below only sends. No other action names any. *)
  let clear_targets = match action with
    | Inbox.Clear ->
      List.filter_map (fun (request, position) ->
        match T.keeper_queue_clear_treatment position with
        | T.Cancel_on_server -> Some request
        | T.Drop_from_local_queue | T.Withdraw_before_post | T.Leave_waiting -> None)
        (T.keeper_message_waiting_positions state ~keeper_name)
    | Inbox.Inspect | Inbox.Inspect_peers _ | Inbox.Pause | Inbox.Resume | Inbox.Cancel _ | Inbox.Move_to_end _ | Inbox.Run_next _
    | Inbox.Edit _ | Inbox.Cancel_event _ | Inbox.Prioritize_event _ -> [] in
  let check_control () =
    Result.bind (check_authority ()) (fun () ->
      match control_generation with
      | Some generation when generation <> T.keeper_chat_control_generation state keeper_name ->
          Error "A newer Keeper control superseded this queue request"
      | Some _ | None -> Ok ()) in
  let operator_operation_id = "tui-queue-" ^ Random_id.uuid_v7 () in
  let host = Masc_tui_transport.Workspace_admission.server_peer_host and port = state.T.port in
  let ko = state.T.ui_language = T.Lang_ko in
  let root = "/api/v1/keepers/" ^ Masc_tui_http.percent_encode_path_segment keeper_name in
  (* One queued message on the server, and the verb that cancels it. Both the
     single cancel and /queue clear post to this address. *)
  let operation_path id =
    root ^ "/chat/operations/" ^ Masc_tui_http.percent_encode_path_segment id in
  let cancel_suffix = "cancel" in
  let perform () =
    let open Result.Syntax in
    let* () = check_control () in
    let* receipt = match action with
      | Inbox.Inspect | Inbox.Inspect_peers _ -> Ok []
      | Inbox.Pause | Inbox.Resume ->
        let verb = if action = Inbox.Pause then "pause" else "resume" in
        let* expected_workspace = match expected_workspace with
          | Some identity -> Ok identity
          | None -> Error "Workspace identity is unavailable; input remains retained" in
        let* owner_paused =
          if not local_resume then Ok true else
            (match Masc_tui_loader.load_keeper_roster ~host ~port ~expected_workspace with
             | Error failure -> Error (Keeper_control.roster_failure_message
                 ~credential_sent:(Masc_tui_http.operator_token_present ()) failure)
             | Ok (roster, _) ->
               match Keeper_control.liveness_of_roster roster keeper_name with
               | Keeper_control.Present runtime -> Ok runtime.Tui_decode.kr_paused
               (* A complete roster without the Keeper: no owner is running,
                  and the server refuses chat admission without one, so a
                  local send could only be refused. Name the way out. *)
               | Keeper_control.Absent ->
                 Error "Keeper is not running on the server; boot it, then /queue resume sends the retained input"
               | Keeper_control.Unobserved | Keeper_control.Invalid _ ->
                 Error "Keeper pause state is unavailable; input remains retained") in
        let* () = check_control () in
        (* The retained input leaves as soon as the owner is confirmed, ahead
           of the informational queue reads below. *)
        let confirm confirmation =
          if action = Inbox.Resume then
            Option.iter (fun generation ->
              enqueue_async mailbox
                (P.Keeper_msg (P.Keeper_queue_resume_confirmed
                   (keeper_name, generation, confirmation, resume_input_ids))))
              control_generation in
        if not owner_paused then begin
          confirm P.Owner_already_active;
          (* This is a read, not a POST receipt. The read-scoped confirmation
             above owns it; the operation completion must not promote it
             across a withdrawn workspace read authority. *)
          Ok []
        end else
        let* status, body = Masc_tui_http.post_keeper_directive ~host ~port ~keeper_name
          ~action:verb ~operator_operation_id ~expected_workspace in
        (match Keeper_control.classify_response ~status ~body with
         | Keeper_control.Accepted _ -> confirm P.Owner_resumed; Ok ["Server confirmed queue " ^ verb]
         | Keeper_control.Committed_followup_failed detail
         | Keeper_control.Rejected {detail;_}
         | Keeper_control.Paused_owner_conflict detail -> Error detail
         | Keeper_control.Purge_accepted _ | Keeper_control.Unbound_purge_receipt _ ->
             Error "Unexpected purge response to queue directive")
      | Inbox.Cancel_event (reference, incarnation, _) | Inbox.Prioritize_event (reference, incarnation, _) ->
        let fields = ["schema", `String "keeper_event_queue.operator.request.v2";
          "source_ref", `String reference; "source_incarnation", `String (Int64.to_string incarnation)] in
        let fields = match action with
          | Inbox.Cancel_event (_, _, reason) ->
            ("action", `String "cancel") :: ("reason", `String reason)
            :: ("operator_operation_id", `String operator_operation_id) :: fields
          | Inbox.Prioritize_event (_, _, urgency) ->
            ("action", `String "reprioritize") :: ("urgency", `String (Keeper_event_queue.urgency_to_string urgency)) :: fields
          | Inbox.Inspect | Inbox.Inspect_peers _ | Inbox.Pause | Inbox.Resume | Inbox.Clear
          | Inbox.Cancel _ | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _ -> assert false in
        let* _ = post_json ~host ~port ~path:(root ^ "/events/operator")
          ~body:(Yojson.Safe.to_string (`Assoc fields)) in
        Ok ["Server confirmed event update: " ^ reference]
      | Inbox.Clear ->
        (* Each line is its own operation on the server, so one failure says
           nothing about the next: every cancel is attempted and answered by
           id. "Not sent" is this client declining to send. "Not confirmed"
           is a refusal or an answer that never arrived, and the snapshot
           read below shows which lines are still queued. *)
        let receipts = List.map (fun (request : Keeper_chat.request) ->
          let id = request.Keeper_chat.request_id in
          match check_authority () with
          | Error detail -> "Cancel not sent for " ^ id ^ ": " ^ detail
          | Ok () ->
            (match Masc_tui_http.post_json ~host ~port
                     ~path:(operation_path id ^ "/" ^ cancel_suffix)
                     ~body:(Yojson.Safe.to_string (`Assoc [])) with
             | Ok _ -> "Server confirmed cancel: " ^ id
             | Error detail -> "Cancel not confirmed for " ^ id ^ ": " ^ detail))
          clear_targets in
        Ok (match receipts with [] -> ["No server messages were selected for cancellation"] | _ -> receipts)
      | Inbox.Run_next id ->
        let* () = check_control () in
        let* detail = Masc_tui_http.post_keeper_run_next ~host ~port ~keeper_name ~request_id:id () in
        Ok [detail]
      | Inbox.Cancel id | Inbox.Move_to_end id | Inbox.Edit (id, _) ->
        let path = operation_path id in
        let* suffix, body = match action with
          | Inbox.Cancel _ -> Ok (cancel_suffix, `Assoc [])
          | Inbox.Move_to_end _ -> Ok ("move-to-end", `Assoc [])
          | Inbox.Edit (_, message) ->
            let* operation = get_json ~host ~port ~path in
            let* input = Inbox.edited_input ~message operation in
            Ok ("edit", `Assoc ["input", input])
          | Inbox.Inspect | Inbox.Inspect_peers _ | Inbox.Pause | Inbox.Resume | Inbox.Clear
          | Inbox.Run_next _ | Inbox.Cancel_event _ | Inbox.Prioritize_event _ -> assert false in
        let* _ = post_json ~host ~port ~path:(path ^ "/" ^ suffix)
          ~body:(Yojson.Safe.to_string body) in
        Ok ["Server confirmed " ^ suffix ^ ": " ^ id] in
    (* Publish the mutation receipt before the follow-up reads, so another
       priority request does not wait on inventory pagination. *)
    (match action with
     | Inbox.Inspect | Inbox.Inspect_peers _ -> ()
     | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _ | Inbox.Move_to_end _
     | Inbox.Run_next _ | Inbox.Edit _ | Inbox.Cancel_event _ | Inbox.Prioritize_event _ ->
         enqueue_async mailbox (P.Keeper_msg (P.Keeper_queue_action_received (keeper_name, receipt))));
    (* Keep each failed read visible beside any successful mutation receipt. *)
    let observe () =
    let waiting = match action with
      | Inbox.Inspect_peers _ -> Ok []
      | Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
      | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
      | Inbox.Cancel_event _ | Inbox.Prioritize_event _ ->
          get_json ~host ~port ~path:(root ^ "/waiting-inventory")
          |> fun result -> Result.bind result (Inbox.waiting_items ~ko ~now:(Unix.gettimeofday ())) in
    let module Operation_ids = Set.Make(String) in
    let rec read_messages after_sequence seen reversed_pages =
      let suffix = Option.fold ~none:"" ~some:(fun value -> "&after_sequence=" ^ value) after_sequence in
      let* page = get_json ~host ~port ~path:(root ^ "/chat/operations?state=queued" ^ suffix) in
      let* next = Inbox.next_sequence page in
      let* items = Inbox.operation_items page in
      let* seen = List.fold_left (fun seen (item : Inbox.item) ->
        let* seen = seen in
        match item.Inbox.id with
        | Some (Inbox.Server_message id) ->
          if Operation_ids.mem id seen then Error "Server queue changed while reading pages; refresh to try again"
          else Ok (Operation_ids.add id seen)
        | Some (Inbox.Local_message _ | Inbox.Running_message _ | Inbox.Event _ | Inbox.Schedule _) | None -> Ok seen)
          (Ok seen) items in
      let rows = List.filter (fun (item : Inbox.item) -> Option.is_some item.Inbox.id) items in
      match next, after_sequence with
      | Some next, Some previous when Int64.of_string next <= Int64.of_string previous ->
        Error "Queue pagination did not advance"
      | Some next, _ -> read_messages (Some next) seen (rows :: reversed_pages)
      | None, _ ->
        let operations = List.concat (List.rev (rows :: reversed_pages)) in
        Ok ({Inbox.id=None; text=Printf.sprintf "Server queued messages · %d" (List.length operations)} :: operations) in
    let peer_result = match action with
      | Inbox.Inspect_peers (_, after_sequence) ->
          let suffix = Option.fold ~none:"" ~some:(fun value ->
            "&after_sequence=" ^ Masc_tui_http.percent_encode_query_value value) after_sequence in
          Some (Inbox.read_peer_page ~keeper_name ~after_sequence ~read_page:(fun () ->
            get_json ~host ~port ~path:(root ^ "/chat/operations?state=queued" ^ suffix)))
      | Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
      | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
      | Inbox.Cancel_event _ | Inbox.Prioritize_event _ -> None in
    let operations = match action, peer_result with
      | Inbox.Inspect_peers _, Some result -> Result.map (fun _ -> []) result
      | Inbox.Inspect_peers _, None -> Error "Keeper relationship page was not read"
      | (Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
        | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
        | Inbox.Cancel_event _ | Inbox.Prioritize_event _), _ -> read_messages None Operation_ids.empty [] in
    let peer_page = Option.bind peer_result Result.to_option in
    Ok {Inbox.waiting; operations; peer_page} in
    let observation = try observe () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn) in
    Ok (receipt, observation) in
  let failed result = Result.map_error (fun detail -> T.Request_failed detail) result in
  let read = match action with
    | Inbox.Inspect_peers _ ->
      let read = Masc_tui_transport.Workspace_admission.capture_json_read state perform in
      (fun () -> match read () with
        | Error refusal -> Error (T.Request_withdrawn refusal)
        | Ok result -> failed result)
    | Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
    | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
    | Inbox.Cancel_event _ | Inbox.Prioritize_event _ -> (fun () -> failed (perform ())) in
  let run () =
    let result = try read () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (T.Request_failed (Printexc.to_string exn)) in
    enqueue_async mailbox (P.Keeper_msg (P.Keeper_queue_loaded (keeper_name, control_generation, action, result))) in
  (* Said here, past both refusals above. The job can still send none: it
     checks the workspace and the control generation first and reports a
     failure of either, and without an Eio switch it does not start. *)
  let cancelling = match clear_targets with
    | [] -> []
    | _ :: _ ->
      [Printf.sprintf "Cancelling %d in the server queue" (List.length clear_targets)] in
  (match action with
   | Inbox.Inspect_peers _ -> ()
   | Inbox.Inspect | Inbox.Pause | Inbox.Resume | Inbox.Clear | Inbox.Cancel _
   | Inbox.Move_to_end _ | Inbox.Run_next _ | Inbox.Edit _
   | Inbox.Cancel_event _ | Inbox.Prioritize_event _ ->
       (match state.T.queue_panel with
        | Some panel when String.equal panel.T.qp_keeper keeper_name ->
          state.T.queue_panel <- Some {panel with T.qp_reading=T.Queue_loading;
            qp_notice=Some (T.Queue_info (if action = Inbox.Inspect then "Reading queue" else "Sending queue change"))}
        | Some _ | None ->
          if action <> Inbox.Inspect then
            Chat_notice.chat_notice state ~keeper_name:(Some keeper_name) ~kind:Chat_notice.Notice_reply
              (String.concat " · " (cancelling @ ["Sending queue change"]))));
  match Eio_context.get_switch_opt () with
  | Some sw -> Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run
  | None -> enqueue_async mailbox (P.Keeper_msg (P.Keeper_queue_loaded (keeper_name, control_generation, action, Error (T.Request_failed "Eio switch is unavailable"))))
  end
  end

let open_keeper_queue_panel (state : T.state) ~mailbox ~keeper_name =
  state.T.queue_panel <- Some
    { T.qp_keeper=keeper_name; qp_layout=Masc_tui_queue_layout.Adaptive; qp_reading=T.Queue_unavailable;
      qp_observation=None; qp_notice=None; qp_receipt=None; qp_selected=None; qp_scroll=0;
      qp_detail=None; qp_detail_scroll=0; qp_refresh_after_priority=false };
  launch_keeper_queue state ~mailbox ~keeper_name Inbox.Inspect

let refresh_queue_after_priority (state : T.state) ~mailbox ~keeper_name =
  match state.T.queue_panel with
  | Some panel when String.equal panel.T.qp_keeper keeper_name
      && panel.T.qp_refresh_after_priority
      && T.server_authority_ready state
      && not (List.mem keeper_name state.T.keeper_queue_inflight)
      && not (List.exists (fun (request : Keeper_chat.request) ->
           String.equal request.Keeper_chat.keeper_name keeper_name) state.T.keeper_run_next_inflight) ->
    state.T.queue_panel <- Some {panel with T.qp_refresh_after_priority=false};
    launch_keeper_queue state ~mailbox ~keeper_name Inbox.Inspect
  | Some _ | None -> ()
