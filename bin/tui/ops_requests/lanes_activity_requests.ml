module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Kept_request = Masc_tui_words.Kept_request
module Lane_inv = Masc.Tui_decode_lane_inventory
module Runtime_cfg_view = Masc_tui_runtime_config_view

let launch_lanes_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
  if state.T.standalone_lanes_inflight then ()
  else begin
    state.T.standalone_lanes_inflight <- true;
    state.T.lanes_owed <- Masc_tui_owed_read.started state.T.lanes_owed;
    let host = Admission.server_peer_host in
    let port = state.T.port in
    state.T.standalone_lanes_generation <- state.T.standalone_lanes_generation + 1;
    let standalone_generation = state.T.standalone_lanes_generation in
    Admission.launch_guarded_request state ~mailbox ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~deliver:(fun result -> P.Lane_msg (P.Lane_inventory_loaded (standalone_generation, result)))
      (fun () -> Masc_tui_loader.load_lane_inventory ~host ~port
        |> Masc_tui_async_read.attribute Masc_tui_async_read.Standalone_lanes
        |> Result.map_error (fun detail -> T.Request_failed detail))
  end
  end

(* A re-read that has to happen: a write's read-back, or the operator's [r].
   A load already out may have left before the change it has to show, so
   one more is queued behind it instead of the request being dropped. *)

let launch_lanes_reread (state : T.state) ~mailbox =
  if state.T.standalone_lanes_inflight
  then state.T.standalone_lanes_reread_pending <- true
  else launch_lanes_load state ~mailbox

let launch_machine_activity_read (state : T.state) ~mailbox owner =
  if T.server_authority_ready state then begin
  match T.machine_activity_session state owner with
  | None -> ()
  | Some session ->
    state.T.machine_activity_generation <- state.T.machine_activity_generation + 1;
    (match Masc_tui_machine_activity.start_read ~generation:state.T.machine_activity_generation session with
     | None -> ()
     | Some (session, request) ->
       T.put_machine_activity state session;
       let host = Admission.server_peer_host and port = state.T.port in
       let check = Admission.capture_admission state ~mailbox in
       Admission.launch_guarded_request state ~mailbox ~boundary_error:(fun detail -> T.Request_failed detail)
         ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
         ~deliver:(fun result -> P.Machine_msg (P.Machine_activity_read (request,result))) (fun () ->
           let document = Result.map (fun (reading : Runtime_cfg_view.reading) ->
             {Masc_tui_runtime_config_edit.path=reading.Runtime_cfg_view.path;
              source_text=reading.Runtime_cfg_view.source_text;
              source_revision=reading.Runtime_cfg_view.metadata.Runtime_cfg_view.source_revision})
             (Masc_tui_loader.load_runtime_config_view ~host ~port) in
           let check () = Result.map_error (fun refusal -> T.Request_withdrawn refusal) (check ()) in
           Result.bind (check ()
             |> Result.map_error (Request_notice.request_failure_after_read state ~request:Kept_request.Runtime_config_read)) (fun () ->
           let activity = Result.bind (Masc_tui_loader.load_lane_inventory ~host ~port)
             (fun (snapshot : Lane_inv.snapshot) ->
               match List.find_opt (fun (row : Lane_inv.row) ->
                 row.Lane_inv.selection = Lane_inv.Machine owner.Masc_tui_machine_activity.machine) snapshot.Lane_inv.rows with
               | Some {Lane_inv.state=Lane_inv.Machine_state (activity,_);_} ->
                   Ok (match activity with
                     | Lane_inv.Machine_enabled -> Machine_configuration.Enabled
                     | Lane_inv.Machine_disabled -> Machine_configuration.Disabled
                     | Lane_inv.Machine_unobserved -> Machine_configuration.Unobserved)
               | None
               | Some {Lane_inv.state=(Lane_inv.Exact_state _ | Lane_inv.Browser_clients _ | Lane_inv.Package_state _);_} ->
                   Error "The selected machine is absent from the server reading.") in
           Result.map (fun () -> {Masc_tui_machine_activity.document;activity})
             (check ()
              |> Result.map_error (Request_notice.request_failure_after_read state ~request:Kept_request.Lanes_read)))))
  end

let launch_machine_activity_save (state : T.state) ~mailbox session =
  let module Activity = Masc_tui_machine_activity in
  state.T.machine_activity_generation <- state.T.machine_activity_generation + 1;
  match Activity.start_save ~generation:state.T.machine_activity_generation session with
  | Error notice ->
    Masc_tui_loader.report_action state "error"
      (Masc_tui_activity_notice.text ~ko:(state.T.ui_language = T.Lang_ko) notice)
  | Ok (session,request,write) ->
    T.put_machine_activity state session;
    let authority=state.T.workspace_authority and identity=state.T.server_identity in
    Admission.launch_guarded_request state ~mailbox
      ~boundary_error:(fun detail -> `Save (Masc_tui_http.Runtime_config_save_refused detail))
      ~withdrawn:(fun refusal -> `Kept_back refusal)
      ~deliver:(fun result ->
        let result = match result with
          | Ok receipt -> Ok (Activity.Saved receipt)
          | Error (`Save (Masc_tui_http.Runtime_config_conflict current)) -> Ok (Activity.Conflict current)
          | Error (`Save (Masc_tui_http.Runtime_config_save_refused detail)) -> Ok (Activity.Refused detail)
          | Error (`Save (Masc_tui_http.Runtime_config_save_unconfirmed detail)) ->
              Ok (Activity.Unconfirmed detail)
          | Error (`Kept_back refusal) -> Error refusal in
        P.Machine_msg (P.Machine_activity_saved (request,result)))
      (fun () -> Masc_tui_surface_requests.Runtime_config_requests.save_runtime_config_text ~prior_contact:Masc_tui_server_lifecycle.Server_reached state ~mailbox ~authority ~identity
        ~expected_source_path:write.Activity.expected_source_path ~expected_source_revision:write.Activity.expected_source_revision write.Activity.source_text)

let open_machine_activity (state : T.state) ~mailbox machine =
  match T.runtime_config_workspace state with
  | None -> Masc_tui_loader.report_action state "error" "Verify the workspace before editing Lane activity."
  | Some workspace ->
    let owner = {Masc_tui_machine_activity.workspace;machine} in
    if T.machine_activity_session state owner=None then
      T.put_machine_activity state (Masc_tui_machine_activity.create owner);
    state.T.exact_activity_open <- None;
    state.T.machine_activity_open <- Some owner;
    state.T.lane_run_detail_scroll <- 0;
    launch_machine_activity_read state ~mailbox owner

let launch_exact_activity_read (state : T.state) ~mailbox owner =
  if T.server_authority_ready state then begin
  match T.exact_activity_session state owner with
  | None -> ()
  | Some session ->
    state.T.exact_activity_generation <- state.T.exact_activity_generation + 1;
    (match Masc_tui_exact_activity.start_read ~generation:state.T.exact_activity_generation session with
     | None -> ()
     | Some (session, request) ->
       T.put_exact_activity state session;
       let host = Admission.server_peer_host and port = state.T.port in
       Admission.launch_guarded_request state ~mailbox ~boundary_error:(fun detail -> T.Request_failed detail)
         ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
         ~deliver:(fun result -> P.Exact_msg (P.Exact_activity_read (request,result))) (fun () ->
           Masc_tui_loader.load_runtime_config_view ~host ~port
           |> Result.map (fun (reading : Runtime_cfg_view.reading) ->
             {Masc_tui_runtime_config_edit.path=reading.Runtime_cfg_view.path;source_text=reading.Runtime_cfg_view.source_text;
              source_revision=reading.Runtime_cfg_view.metadata.Runtime_cfg_view.source_revision})
           |> Result.map_error (fun detail -> T.Request_failed detail)))
  end

let launch_exact_activity_save (state : T.state) ~mailbox session =
  let module Activity = Masc_tui_exact_activity in
  state.T.exact_activity_generation <- state.T.exact_activity_generation + 1;
  match Activity.start_save ~generation:state.T.exact_activity_generation session with
  | Error notice ->
    Masc_tui_loader.report_action state "error"
      (Masc_tui_activity_notice.text ~ko:(state.T.ui_language = T.Lang_ko) notice)
  | Ok (session,request,write) ->
    T.put_exact_activity state session;
    let authority=state.T.workspace_authority and identity=state.T.server_identity in
    Admission.launch_guarded_request state ~mailbox
      ~boundary_error:(fun detail -> `Save (Masc_tui_http.Runtime_config_save_refused detail))
      ~withdrawn:(fun refusal -> `Kept_back refusal)
      ~deliver:(fun result ->
        let result = match result with
          | Ok receipt -> Ok (Activity.Saved receipt)
          | Error (`Save (Masc_tui_http.Runtime_config_conflict current)) -> Ok (Activity.Conflict current)
          | Error (`Save (Masc_tui_http.Runtime_config_save_refused detail)) -> Ok (Activity.Refused detail)
          | Error (`Save (Masc_tui_http.Runtime_config_save_unconfirmed detail)) ->
              Ok (Activity.Unconfirmed detail)
          | Error (`Kept_back refusal) -> Error refusal in
        P.Exact_msg (P.Exact_activity_saved (request,result)))
      (fun () -> Masc_tui_surface_requests.Runtime_config_requests.save_runtime_config_text ~prior_contact:Masc_tui_server_lifecycle.Server_reached state ~mailbox ~authority ~identity
        ~expected_source_path:write.Activity.expected_source_path ~expected_source_revision:write.Activity.expected_source_revision write.Activity.source_text)

let open_exact_activity (state : T.state) ~mailbox lane =
  match T.runtime_config_workspace state with
  | None -> Masc_tui_loader.report_action state "error" "Verify the workspace before editing Lane activity."
  | Some workspace ->
    let owner = {Masc_tui_exact_activity.workspace;lane} in
    if T.exact_activity_session state owner=None then
      T.put_exact_activity state (Masc_tui_exact_activity.create owner);
    state.T.machine_activity_open <- None;
    state.T.exact_activity_open <- Some owner;
    state.T.lane_run_detail_scroll <- 0;
    launch_exact_activity_read state ~mailbox owner

let launch_lane_runs_load ?before (state : T.state) ~mailbox ~(lane : Lane_run_identity.t) =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  state.T.lane_runs_generation <- state.T.lane_runs_generation + 1;
  let generation = state.T.lane_runs_generation in
  state.T.lane_runs_loading <- true;
  let host = Admission.server_peer_host in
  let port = state.T.port in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Lane_msg (P.Lane_runs_loaded (lane, generation, before, result))))
    (fun () -> Masc_tui_http.fetch_lane_runs ?before ~host ~port ~lane ())
  end

let launch_lane_run_detail_load (state : T.state) ~mailbox ~run_id =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  state.T.lane_run_detail_generation <- state.T.lane_run_detail_generation + 1;
  let generation = state.T.lane_run_detail_generation in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Lane_msg (P.Lane_run_detail_loaded (run_id, generation, result))))
    (fun () -> Masc_tui_http.fetch_lane_run_detail ~host ~port ~run_id)
  end

(* History targets are logical observation identities. Opening one drops the
   previous list; it never requires a current configuration/installation row. *)

let open_lane_run_list (state : T.state) ~mailbox (lane : Lane_run_identity.t) =
  T.begin_lane_run_list state lane;
  launch_lane_runs_load state ~mailbox ~lane

let open_lane_run_detail (state : T.state) ~mailbox ~(lane : Lane_run_identity.t) ~run_id =
  state.T.lanes_mode <- T.Lanes_run_detail (lane, run_id);
  state.T.lane_run_detail <- None;
  state.T.lane_run_detail_error <- None;
  state.T.lane_run_detail_scroll <- 0;
  state.T.lane_run_detail_content_height <- 0;
  launch_lane_run_detail_load state ~mailbox ~run_id

(* The run under the list cursor. Enter opens it from the list, and [ and ]
   reopen through it after moving the cursor under an open detail, so a step
   reads everything an open reads. *)
let open_selected_lane_run (state : T.state) ~mailbox ~(lane : Lane_run_identity.t) =
  match
    Option.bind state.T.lane_runs (fun runs ->
      List.nth_opt runs state.T.lane_runs_cursor)
  with
  | Some (run : Masc.Tui_decode.lane_run_summary) ->
      open_lane_run_detail state ~mailbox ~lane ~run_id:run.Masc.Tui_decode.lrs_run_id
  | None -> ()

let launch_measurement_artifact_load (state : T.state) ~mailbox ~sha256 =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  state.T.lane_run_detail_generation <- state.T.lane_run_detail_generation + 1;
  let generation = state.T.lane_run_detail_generation in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Measurement_artifact_loaded (sha256, generation, result)))
    (fun () -> Masc_tui_http.fetch_measurement_artifact ~host ~port ~sha256)
  end

let open_measurement_artifact (state : T.state) ~mailbox ~sha256 =
  state.T.lanes_mode <- T.Lanes_measurement_detail sha256;
  state.T.measurement_report <- None;
  state.T.lane_run_detail_error <- None;
  state.T.lane_run_detail_scroll <- 0;
  state.T.lane_run_detail_content_height <- 0;
  launch_measurement_artifact_load state ~mailbox ~sha256
