module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission

let launch_fusion_runs_load ?(demand = Masc_tui_fusion_updates.Share) (state : T.state) ~mailbox =
  let enqueue_async = Admission.workspace_enqueue state in
  if T.server_authority_ready state then
  match Masc_tui_fusion_updates.begin_runs state ~demand with
  | None -> ()
  | Some request ->
      let host = Admission.server_peer_host in
      let port = state.T.port in
      let read = Admission.capture_json_read state (fun () ->
        Masc_tui_loader.load_fusion_runs ~host ~port) in
      let run () =
        let result =
          try (match read () with
            | Error refusal -> Error (T.Request_withdrawn refusal)
            | Ok result -> Result.map_error (fun detail -> T.Request_failed detail) result) with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (T.Request_failed (Printexc.to_string exn))
        in
        enqueue_async mailbox (P.Fusion_msg (P.Fusion_runs_loaded (request, result)))
      in
      (match Eio_context.get_switch_opt () with
       | Some sw ->
           Eio.Fiber.fork_daemon ~sw (fun () ->
               run ();
               `Stop_daemon)
       | None ->
           enqueue_async mailbox
             (P.Fusion_msg (P.Fusion_runs_loaded
                (request, Error (T.Request_failed "Eio switch is unavailable")))))

let revalidate_visible_fusion (state : T.state) ~mailbox =
  let demand = Masc_tui_fusion_updates.After_change in
  Masc_tui_fusion_updates.revalidate_visible state
    ~runs:(fun () -> launch_fusion_runs_load ~demand state ~mailbox)
    ~detail:(fun run_id -> Masc_tui_work_actions.Detail_navigation.launch_fusion_detail_load ~demand state ~mailbox ~run_id)
    ~historical:(fun reference ->
      Masc_tui_work_actions.Detail_navigation.launch_fusion_historical_detail_load ~demand state ~mailbox ~reference)

let resume_fusion_after_observer_failure (state : T.state) ~mailbox =
  Masc_tui_fusion_updates.observer_failed state
    ~runs:(fun () -> launch_fusion_runs_load state ~mailbox)
    ~detail:(fun run_id -> Masc_tui_work_actions.Detail_navigation.launch_fusion_detail_load state ~mailbox ~run_id)
    ~historical:(fun reference ->
      Masc_tui_work_actions.Detail_navigation.launch_fusion_historical_detail_load state ~mailbox ~reference)

(* The two requests behind the launch form. Neither is inflight-guarded by
   a field of its own: the form's state says which request it waits on, and
   the generation in the answer says whether it is still that one. *)

let launch_fusion_launch_options_load (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  state.T.fusion_launch_generation <- state.T.fusion_launch_generation + 1;
  let generation = state.T.fusion_launch_generation in
  state.T.fusion_launch <- Some (T.Fusion_launch_reading_presets generation);
  state.T.fusion_scroll <- 0;
  let host = Admission.server_peer_host in
  let port = state.T.port in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Fusion_msg (P.Fusion_launch_options_loaded (generation, result))))
    (fun () -> Masc_tui_loader.load_fusion_launch_options ~host ~port)
  end

(* Named apart from [Masc_tui_loader.launch_fusion_run], which it calls: one
   name for both is a shadow that turns a missing qualifier into unbounded
   recursion rather than a compile error. *)

let start_fusion_run (state : T.state) ~mailbox ~(request : Masc_tui_fusion_launch.request) =
  state.T.fusion_launch_generation <- state.T.fusion_launch_generation + 1;
  let generation = state.T.fusion_launch_generation in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  Admission.launch_guarded_request state ~mailbox ~boundary_error:(fun detail -> T.Request_failed detail)
    ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
    ~deliver:(fun result -> P.Fusion_msg (P.Fusion_launched (generation, result)))
    (fun () -> Masc_tui_loader.launch_fusion_run ~host ~port ~request
      |> Result.map_error (fun detail -> T.Request_failed detail))
