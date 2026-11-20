module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission

let launch_harness_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  if state.T.harness_inflight then ()
  else begin
    state.T.harness_inflight <- true;
    state.T.harness_owed <- Masc_tui_owed_read.started state.T.harness_owed;
    let host = Admission.server_peer_host in
    let port = state.T.port in
    Admission.launch_async_read state ~mailbox
      ~on_not_run:(fun () ->
        state.T.harness_inflight <- false;
        state.T.harness_owed <- Masc_tui_owed_read.abandoned state.T.harness_owed)
      ~deliver:(fun result ->
        enqueue_async mailbox (P.Harness_msg (P.Harness_loaded result)))
      (fun () -> Masc_tui_loader.load_harness ~host ~port)
  end
  end

(* The Home Health line, drawn on every surface. *)
let launch_overview_load (state : T.state) ~mailbox =
  if T.server_authority_ready state && not state.T.overview_inflight then begin
    let enqueue_async = Admission.workspace_enqueue state in
    state.T.overview_inflight <- true;
    state.T.overview_owed <- Masc_tui_owed_read.started state.T.overview_owed;
    let host = Admission.server_peer_host in
    let port = state.T.port in
    Admission.launch_async_read state ~mailbox
      ~on_not_run:(fun () ->
        state.T.overview_inflight <- false;
        state.T.overview_owed <- Masc_tui_owed_read.abandoned state.T.overview_owed)
      ~deliver:(fun result -> enqueue_async mailbox (P.Overview_loaded result))
      (fun () -> Masc_tui_loader.load_overview ~host ~port)
  end

let launch_clients_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  if state.T.clients_surface_inflight then ()
  else begin
    state.T.clients_surface_inflight <- true;
    (* Marks the read in flight on the owed read, so the answer settles
       it rather than leaving it due for the next loop. *)
    T.begin_clients_read state;
    let host = Admission.server_peer_host in
    let port = state.T.port in
    state.T.clients_surface_generation <- state.T.clients_surface_generation + 1;
    let generation = state.T.clients_surface_generation in
    Admission.launch_async_read state ~mailbox
      ~on_not_run:(fun () ->
        state.T.clients_surface_inflight <- false;
        T.abandon_clients_read state)
      ~deliver:(fun result ->
        enqueue_async mailbox (P.Clients_loaded (generation, result)))
      (fun () -> Masc_tui_loader.load_clients ~host ~port)
  end
  end
