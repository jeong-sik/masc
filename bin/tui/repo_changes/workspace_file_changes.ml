module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Tui_decode = Masc.Tui_decode

(* The window the Changes surface asks for. A day is what an operator means
   by "what has this keeper been doing"; the server's own ceiling is what the
   read costs, and it clamps anything wider. *)
let changes_window_hours = 24.0

let launch_workspace_activity (state : T.state) ~mailbox ~repo_id =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  match Masc_tui_fetched.start ~equal:String.equal state.T.workspace_activity ~key:repo_id with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) ->
      state.T.workspace_activity <- next;
      let host = Admission.server_peer_host and port = state.T.port in
      let run () =
        let result = try Masc_tui_http.fetch_repository_activity ~host ~port
            ~repo_id ~window_hours:changes_window_hours
          with Eio.Cancel.Cancelled _ as exn -> raise exn
             | exn -> Error (Printexc.to_string exn) in
        let result = Result.bind result (fun snapshot ->
          if String.equal snapshot.Tui_decode.ras_repo_id repo_id then Ok snapshot
          else Error "repository activity response names another repository") in
        enqueue_async mailbox (P.Workspace_msg (P.Workspace_activity_loaded (request, result)))
      in
      match Eio_context.get_switch_opt () with
      | Some sw -> Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)
      | None -> enqueue_async mailbox (P.Workspace_msg (P.Workspace_activity_loaded (request, Error "Eio switch is unavailable")))
  end

let launch_file_changes_load (state : T.state) ~mailbox ~keeper_name =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  state.T.changes_inflight <- true;
  Admission.launch_guarded_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.File_changes_loaded (keeper_name, result)))
    (Admission.capture_json_read state (fun () ->
      Masc_tui_loader.load_keeper_file_changes ~host ~port ~keeper_name
        ~window_hours:changes_window_hours))
  end

(* The pane's Changes tab asks for the selected keeper's changes through
   the fetch helper, so a request already in flight is not repeated and an
   answer for another keeper is dropped on arrival. *)

let launch_acting_pane_changes_load ?(force = false) (state : T.state) ~mailbox ~keeper_name =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  let key = { T.apk_keeper = keeper_name
            ; apk_scope = state.T.workspace_authority, state.T.workspace_read_authority } in
  let start =
    match force, Masc_tui_fetched.current_key state.T.acting_pane_changes with
    | true, _ -> Masc_tui_fetched.refresh
    | false, Some current when Masc_tui_fetched.in_flight state.T.acting_pane_changes
                        && not (T.same_acting_pane_key current key) -> Masc_tui_fetched.refresh
    | false, (Some _ | None) -> Masc_tui_fetched.start
  in
  match
    start ~equal:(if force then T.same_acting_pane_key else T.same_acting_pane_keeper)
      state.T.acting_pane_changes ~key
  with
  | Masc_tui_fetched.Already_loading -> ()
  | Masc_tui_fetched.Started (next, request) -> (
      state.T.acting_pane_changes_loss_followup <- None;
      state.T.acting_pane_changes <- next;
      let host = Admission.server_peer_host in
      let port = state.T.port in
      Admission.launch_guarded_async_read state ~mailbox
        ~deliver:(fun result ->
          enqueue_async mailbox (P.Acting_pane_changes_loaded (request, result)))
        (Admission.capture_json_read state (fun () ->
          Masc_tui_loader.load_keeper_file_changes ~host ~port ~keeper_name
            ~window_hours:changes_window_hours)))
  end

let acting_pane_source_current (state : T.state) =
  match state.T.acting_pane_presented.Masc_tui_acting_pane.frame_source with
  | Some source when T.same_acting_pane_scope source.T.aps_scope
                       (state.T.workspace_authority, state.T.workspace_read_authority)
                     && T.server_authority_ready state ->
      true
  | Some _ | None -> false

let launch_keeper_chat_file_changes_load ?(force = false) (state : T.state) ~mailbox
    ~keeper_name =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  if state.T.msg_tool_visibility <> T.Tools_full then ()
  else begin
    if
      not
        (Option.equal String.equal state.T.msg_file_changes_keeper
           (Some keeper_name))
    then Masc_tui_chat_input.Message_draft_recall.reset_message_file_changes state (Some keeper_name);
    if state.T.msg_file_changes_loading then
      if force then state.T.msg_file_changes_refresh_pending <- true else ()
    else if
      (Option.is_some state.T.msg_file_changes
       || Option.is_some state.T.msg_file_changes_error)
      && not force
    then ()
    else begin
      state.T.msg_file_changes_generation <- state.T.msg_file_changes_generation + 1;
      let generation = state.T.msg_file_changes_generation in
      state.T.msg_file_changes_loading <- true;
      state.T.msg_file_changes_refresh_pending <- false;
      let host = Admission.server_peer_host in
      let port = state.T.port in
      let read = Admission.capture_json_read state (fun () ->
        Masc_tui_loader.load_keeper_file_changes ~host ~port ~keeper_name
          ~window_hours:changes_window_hours) in
      let run () =
        let result =
          try (match read () with
            | Error refusal -> Error (T.Request_withdrawn refusal)
            | Ok result -> Result.map_error (fun detail -> T.Request_failed detail) result)
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> Error (T.Request_failed (Printexc.to_string exn))
        in
        enqueue_async mailbox
          (P.Keeper_msg (P.Keeper_chat_file_changes_loaded (generation, keeper_name, result)))
      in
      match Eio_context.get_switch_opt () with
      | Some sw ->
          Eio.Fiber.fork_daemon ~sw (fun () ->
              run ();
              `Stop_daemon)
      | None ->
          enqueue_async mailbox
            (P.Keeper_msg (P.Keeper_chat_file_changes_loaded
               ( generation
               , keeper_name
               , Error (T.Request_failed "Eio switch is unavailable") )))
    end
  end
  end

let launch_keeper_chat_tool_details_load ?(force = false) (state : T.state) ~mailbox
    ~keeper_name =
  if T.server_authority_ready state then begin
  if state.T.msg_tool_visibility = T.Tools_compact then ()
  else begin
    launch_keeper_chat_file_changes_load ~force state ~mailbox ~keeper_name;
    Masc_tui_work_requests.Schedule_call_requests.launch_keeper_calls_load ~force state ~mailbox keeper_name
  end
  end

(* Changes follows the selected Keeper, but the surface is useful precisely
   when comparing more than one Keeper. Brackets move that shared selection
   and invalidate every row whose identity belonged to the previous Keeper;
   the stamped async response below already rejects a late answer. *)

let cycle_changes_keeper (state : T.state) ~mailbox ~delta =
  let count = List.length state.T.keepers in
  if count > 0 then begin
    let current =
      match state.T.changes_keeper with
      | Some keeper_name ->
          let rec find index = function
            | [] -> min state.T.keeper_cursor (count - 1)
            | (keeper : T.keeper) :: rest ->
                if String.equal keeper.Tui_decode.k_name keeper_name
                then index
                else find (index + 1) rest
          in
          find 0 state.T.keepers
      | None -> min state.T.keeper_cursor (count - 1)
    in
    let next = (current + delta + count) mod count in
    match List.nth_opt state.T.keepers next with
    | None -> ()
    | Some keeper ->
        state.T.keeper_cursor <- next;
        state.T.changes_keeper <- Some keeper.Tui_decode.k_name;
        state.T.changes <- None;
        state.T.changes_error <- None;
        state.T.changes_inflight <- false;
        state.T.changes_cursor <- 0;
        state.T.changes_scroll <- 0;
        state.T.changes_diff_row <- None;
        state.T.changes_diff_scroll <- 0;
        state.T.changes_tree_diff <- None;
        state.T.changes_tree_diff_error <- None;
        state.T.changes_tree_diff_path <- None;
        launch_file_changes_load state ~mailbox ~keeper_name:keeper.Tui_decode.k_name
  end
