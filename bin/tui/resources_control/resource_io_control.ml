module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Kept_request = Masc_tui_words.Kept_request
module Catalog = Masc_tui_resource_catalog
module Export = Masc_tui_resource_export

let launch_artifact_checks_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then
    match Masc_tui_fetched.refresh ~equal:Unit.equal state.T.artifact_checks ~key:() with
    | Masc_tui_fetched.Already_loading -> ()
    | Masc_tui_fetched.Started (reading, request) ->
      state.T.artifact_checks <- reading;
      let host = Admission.server_peer_host and port = state.T.port in
      Admission.launch_json_read state ~mailbox
        ~boundary_error:(fun detail -> T.Request_failed detail)
        ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
        ~deliver:(fun result -> P.Artifact_msg (P.Artifact_checks_loaded (request, result)))
        (fun () ->
          let open Result.Syntax in
          Result.map_error (fun detail -> T.Request_failed detail)
            (let* json =
               Masc_tui_http.get_json ~host ~port ~path:"/api/v1/published-artifact-checks"
             in
             Masc_tui_artifact_checks.of_json ~received_at:(Unix.gettimeofday ()) json))

let launch_resources_load (state : T.state) ~mailbox =
  Masc_tui_resources_requests.launch_list state ~host:Admission.server_peer_host
    ~launch:(Admission.launch_json_read state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal))
    ~check:(Admission.capture_admission state ~mailbox);
  launch_artifact_checks_load state ~mailbox

let resource_export_is_current (state : T.state) (prompt : T.resource_save_prompt) =
  if state.T.workspace_authority <> prompt.T.rsp_authority
     || state.T.workspace_read_authority != prompt.T.rsp_read_authority then
    Error "The workspace changed; cancel and select the report again"
  else match Masc_tui_resource_document.export_source state with
    | Ok current when Export.same current prompt.T.rsp_document -> Ok ()
    | Ok _ -> Error "The selected report revision changed; cancel and select it again"
    | Error detail -> Error detail

let open_resource_save_prompt (state : T.state) =
  match Masc_tui_resource_document.export_source state with
  | Error detail -> Masc_tui_loader.report_action state "error" detail
  | Ok document ->
    (match T.workspace_input_identity_of_server state.T.server_identity with
     | None -> Masc_tui_loader.report_action state "error" "Confirm the workspace before saving this report"
     | Some workspace ->
       let directory = Sys.getcwd () in
       let path = Masc_tui_message_input.create () in
       Masc_tui_message_input.insert path
         (Filename.concat directory (Export.suggested_name document));
       state.T.resource_save_prompt <- Some {
         T.rsp_owner = ref (); rsp_document = document; rsp_path = path;
         rsp_authority = state.T.workspace_authority;
         rsp_read_authority = state.T.workspace_read_authority;
         rsp_workspace = workspace; rsp_directory = directory; rsp_error = None })

type resource_save_observation =
  | Save_not_entered
  | Save_entered
  | Save_observed of T.resource_save_outcome

let save_resource_source (state : T.state) ~mailbox (prompt : T.resource_save_prompt) =
  match resource_export_is_current state prompt with
  | Error detail -> prompt.T.rsp_error <- Some detail
  | Ok () ->
    let input_path = Masc_tui_message_input.contents prompt.T.rsp_path in
    if String.equal input_path "" then prompt.T.rsp_error <- Some "Enter a destination file path"
    else if T.resource_save_pending_for_prompt state prompt then ()
    else match Eio_context.get_env_opt () with
    | None -> prompt.T.rsp_error <- Some "The local filesystem is unavailable"
    | Some env ->
      let request = {
        T.save_form = prompt.T.rsp_owner;
        save_document = prompt.T.rsp_document; save_input_path = input_path;
        save_path = T.resource_save_path prompt; save_workspace = prompt.T.rsp_workspace } in
      state.T.resource_save_receipts <- {T.save_request=request;save_phase=T.Resource_save_pending}
        :: state.T.resource_save_receipts;
      prompt.T.rsp_error <- None;
      state.T.resource_scroll <- Masc_tui_scroll.Position.first;
      let observed = ref Save_not_entered in
      let boundary detail = match !observed with
        | Save_not_entered -> T.Resource_save_not_started detail
        | Save_entered -> T.Resource_save_unconfirmed {detail;cause=None}
        | Save_observed outcome -> outcome in
      let deliver outcome = P.Resource_msg (P.Resource_saved (request, outcome)) in
      Admission.launch_guarded_request ~operation:true state ~mailbox ~boundary_error:boundary
        ~withdrawn:(fun refusal -> T.Resource_save_kept_back refusal)
        ~cancelled_by:(fun () -> deliver (match !observed with
          | Save_not_entered -> T.Resource_save_not_started "Save cancelled before file creation"
          | Save_entered -> T.Resource_save_interrupted None
          | Save_observed outcome -> outcome))
        ~deliver:(function Ok outcome | Error outcome -> deliver outcome)
        (fun () ->
          match resource_export_is_current state prompt with
          | Error detail -> Ok (T.Resource_save_not_started detail)
          | Ok () ->
            observed := Save_entered;
            match Export.save ~fs:env#fs ~path:request.T.save_path request.T.save_document with
            | result ->
                let outcome = T.Resource_save_result result in
                observed := Save_observed outcome;
                Ok outcome
            | exception (Eio.Cancel.Cancelled _ as exn) ->
                let backtrace = Printexc.get_raw_backtrace () in
                observed := Save_observed (T.Resource_save_interrupted
                  (Export.cancellation exn));
                Printexc.raise_with_backtrace exn backtrace
            | exception exn ->
                let backtrace = Printexc.get_raw_backtrace () in
                (match Export.cancellation exn with
                 | Some cancellation ->
                     observed := Save_observed (T.Resource_save_interrupted (Some cancellation));
                     Printexc.raise_with_backtrace exn backtrace
                 | None ->
                     let outcome = T.Resource_save_unconfirmed {
                       detail=Printexc.to_string exn;cause=Some exn} in
                     observed := Save_observed outcome;
                     Ok outcome))

let open_resource_in_dashboard (state : T.state) ~mailbox =
  match Masc_tui_resource_document.export_source state with
  | Error detail -> Masc_tui_loader.report_action state "error" detail
  | Ok document ->
    let authority = state.T.workspace_authority in
    let reading = state.T.workspace_read_authority in
    let port = state.T.port in
    let url = Export.dashboard_url ~host:Admission.server_peer_host ~port document in
    let failed detail = T.Request_failed detail in
    Admission.launch_guarded_request ~operation:true state ~mailbox ~boundary_error:failed
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~cancelled:(P.Resource_msg (P.Resource_exported (Export.label document,
        Error (failed ("Browser opening interrupted; whether the browser opened is unknown: " ^ url)))))
      ~deliver:(fun result -> P.Resource_msg (P.Resource_exported (Export.label document, result)))
      (fun () ->
        if authority <> state.T.workspace_authority || reading != state.T.workspace_read_authority then
          Error (failed "The workspace changed before opening this report")
        else match Masc_tui_resource_document.export_source state with
        | Error detail -> Error (failed detail)
        | Ok current when not (Export.same current document) ->
            Error (failed "The selected report changed before opening")
        | Ok _ ->
          Eio_guard.run_in_systhread ~label:"tui-report-browser" (fun () ->
            Masc_tui_browser.open_url url)
          |> Result.map (fun opener -> "Opened " ^ url ^ " via " ^ opener ^ "; browser authentication may be required")
          |> Result.map_error failed)

let launch_resources_read ~withdraw_diagram (state : T.state) ~mailbox ~key =
  withdraw_diagram state;
  let share_origin = Result.to_option (T.workspace_change_origin state) in
  Masc_tui_resources_requests.launch_read state ~host:Admission.server_peer_host
    ~share_origin
    ~launch:(Admission.launch_json_read state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal))
    ~check:(Admission.capture_admission state ~mailbox) ~key

let launch_artifact_check_change (state : T.state) ~mailbox =
  let entry = match state.T.resource_focus with
    | T.Right_pane -> Option.map Masc_tui_resource_document.entry
        (Masc_tui_resource_document.current state)
    | T.Left_pane -> Option.bind (T.visible_resources state) (fun entries ->
        List.nth_opt entries state.T.resources_cursor) in
  match entry, state.T.server_identity with
  | (None | Some (Catalog.Mcp _)), _ ->
    Masc_tui_loader.report_action state "error" "Select a published report revision to check or uncheck"
  | Some (Catalog.Report _), None ->
    Request_notice.report_kept_back state ~request:Kept_request.Report_check
      Masc_tui_words.workspace_identity_unread Masc_tui_words.Nothing_kept
  | Some (Catalog.Report report), Some expected_workspace ->
    match Masc_tui_resources_updates.begin_check state ~report with
    | Error (T.Request_failed detail) -> Masc_tui_loader.report_action state "error" detail
    | Error (T.Request_withdrawn refusal) ->
      Request_notice.report_withdrawn state ~request:Kept_request.Report_check refusal
    | Ok request ->
      let credential = Masc_tui_http.bind_credential () in
      let host = Admission.server_peer_host and port = state.T.port in
      Masc_tui_loader.report_action state "system" "Saving confirmation; refresh follows the result";
      Admission.launch_guarded_request ~operation:true state ~mailbox
        ~boundary_error:(fun detail -> T.Request_failed detail)
        ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
        ~deliver:(fun result -> P.Artifact_msg (P.Artifact_check_changed (request, result)))
        (fun () -> Masc_tui_http.post_artifact_check ~credential ~expected_workspace
          ~host ~port ~request
          |> Result.map_error (fun detail -> T.Request_failed detail))
