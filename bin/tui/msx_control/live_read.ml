module T = Masc_tui_types
module P = Masc_tui_async_protocol

let launch_msx_live_read (state : T.state) ~mailbox =
  if not (T.server_authority_ready state) || Option.is_some (Checkpoint_control.checkpoint_for_workspace state) then () else
  let current_view = state.T.msx_view_authority in
  match state.T.msx_live_in_flight with
  | Some pending when pending.T.live_view == current_view && pending.T.live_port = state.T.port -> ()
  | Some _ | None ->
    (* An abandoned view's slow read does not own the reopened screen. Its
       reply still has to match this exact slot before it can settle it. *)
    let request = { T.live_view = current_view; live_port = state.T.port } in
    let since = Masc_tui_machine_live.since state.T.msx_live in
    let expected_workspace = state.T.server_identity in
    state.T.msx_live_owed <- Masc_tui_owed_read.started state.T.msx_live_owed;
    state.T.msx_live_in_flight <- Some request;
    Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~deliver:(fun result -> P.Msx_msg (P.Msx_live_loaded (request, result)))
      (fun () -> Masc_tui_http.fetch_machine_live ?expected_workspace
        ~host:Masc_tui_transport.Workspace_admission.server_peer_host
        ~port:request.T.live_port Masc.Machine_lane.Msx ~since
        |> Result.map_error (fun detail -> T.Request_failed detail))

let launch_dos_live_read (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
  let current_view = state.T.msx_view_authority in
  match state.T.dos_live_in_flight with
  | Some pending when pending.T.live_view == current_view && pending.T.live_port = state.T.port -> ()
  | Some _ | None ->
    let request = { T.live_view = current_view; live_port = state.T.port } in
    state.T.dos_live_owed <- Masc_tui_owed_read.started state.T.dos_live_owed;
    state.T.dos_live_in_flight <- Some request;
    let since = Masc_tui_machine_live.since state.T.dos_live in
    Masc_tui_transport.Workspace_admission.launch_guarded_request state ~mailbox
      ~boundary_error:(fun detail -> T.Request_failed detail)
      ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
      ~deliver:(fun result -> P.Dos_live_loaded (request, result))
      (fun () -> Masc_tui_http.fetch_machine_live
        ~host:Masc_tui_transport.Workspace_admission.server_peer_host
        ~port:request.T.live_port Masc.Machine_lane.Dos ~since
        |> Result.map_error (fun detail -> T.Request_failed detail))
  end
