let settle_connector_unbind_offers (state : Masc_tui_types.state)
    (snapshot : Masc.Tui_decode_connectors.connector_snapshot) =
  (* Every Keeper paused or shut down since the last read gets its
     answer from this one. The answering load may have started
     before the pause landed; a pause does not change bindings, so
     what it read is still what the Keeper holds. *)
  let pending = List.rev state.connector_unbind_offer_pending in
  state.connector_unbind_offer_pending <- [];
  state.connector_unbind_offer_origin <- None;
  let unreadable =
    Masc_tui_connector_unbind.unreadable_transports snapshot.cs_connectors
  in
  List.iter
    (fun keeper_name ->
      match
        Masc_tui_connector_unbind.targets ~keeper_name snapshot.cs_connectors
      with
      | [] -> (
          (* No readable binding. An unreadable transport may still
             hold some, and saying nothing would read as none. *)
          match unreadable with
          | [] -> ()
          | _ :: _ ->
              Masc_tui_loader.report_action state "system"
                (Masc_tui_connector_unbind.nothing_to_unbind ~keeper_name
                   ~unreadable))
      | targets ->
          (* The offer takes the next key only where that key would
             mean this Keeper: its row or its detail is the one
             selected, and nothing else is armed. Anywhere else a
             [U] means something else, so the line only informs. *)
          let offer_here =
            Masc_tui_types.shows_selected_keeper state.view
            && (match Masc_tui_types.selected_keeper state with
                | Some (keeper : Masc.Tui_decode.keeper) ->
                    String.equal keeper.k_name keeper_name
                | None -> false)
            && Option.is_none state.connector_unbind_all_armed
            && not state.composer_focused
          in
          if offer_here then begin
            (* The frame count keeps a key typed before this line
               was drawn from answering it. *)
            state.connector_unbind_offer <-
              Some
                { Masc_tui_connector_unbind.offer_keeper = keeper_name
                ; offer_targets = targets
                ; offered_at = state.frames_presented
                };
            Masc_tui_loader.report_action state "system"
              (Masc_tui_connector_unbind.offer_prompt ~keeper_name ~unreadable
                 targets)
          end
          else
            Masc_tui_loader.report_action state "system"
              (Masc_tui_connector_unbind.still_bound ~keeper_name targets))
    pending

let retire_connector_read state = function
  | Masc_tui_types.Connector_read.No_retirement -> ()
  | Masc_tui_types.Connector_read.Retire request ->
      Masc_tui_workspace_job.cancel_observation state
        ~key:(Masc_tui_types.Connector_read.job_key request)

let launch_connectors_load (state : Masc_tui_types.state) ~mailbox =
  match Masc_tui_types.begin_connectors_read state with
  | None -> ()
  | Some request ->
      state.connectors_owed <-
        Masc_tui_owed_read.started state.connectors_owed;
      let enqueue_status =
        Masc_tui_transport.Workspace_admission.workspace_enqueue state
      in
      let host = Masc_tui_transport.Workspace_admission.server_peer_host in
      let port = state.port in
      Masc_tui_transport.Workspace_admission.launch_json_read
        ~key:(Masc_tui_types.Connector_read.job_key request)
        state ~mailbox
        ~boundary_error:(fun detail -> Masc_tui_types.Request_failed detail)
        ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
        ~on_not_run:(fun () ->
          state.connectors_owed <-
            Masc_tui_owed_read.abandoned state.connectors_owed;
          Masc_tui_types.connector_read_not_started state request)
        ~deliver:(fun result ->
          Masc_tui_async_protocol.Connectors_msg
            (Masc_tui_async_protocol.Connectors_loaded
               ( request
               , Result.map_error
                   (Masc_tui_transport.Workspace_admission.attribute_request_failure
                      Masc_tui_async_read.Connectors)
                   result )))
        (fun () ->
          Masc_tui_loader.load_connectors ~host ~port
            ~on_status:(fun snapshot ->
              enqueue_status mailbox
                (Masc_tui_async_protocol.Connectors_msg
                   (Masc_tui_async_protocol.Connectors_status_loaded
                      (request, snapshot))))
          |> Result.map_error (fun detail -> Masc_tui_types.Request_failed detail))

(* A binding write changed what the server holds. A load already in flight
   may have read before the write landed. Coalesce while status is pending;
   once status is known, retire its remaining names work and admit a fresh
   observation without waiting for that metadata or claiming cleanup ended. *)
let reload_connectors_after_write state ~mailbox =
  retire_connector_read state (Masc_tui_types.queue_connectors_after_write state);
  launch_connectors_load state ~mailbox

(* One fiber sends the unbinds in order and reports them together: each
   binding's answer is its own line, so a partial success cannot read as a
   whole one. *)
let launch_connector_unbind_all (state : Masc_tui_types.state) ~mailbox
    ~keeper_name targets =
  let enqueue_async =
    Masc_tui_transport.Workspace_admission.workspace_enqueue state
  in
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  if state.connector_unbind_all_inflight then
    Masc_tui_loader.report_action state "error"
      "unbind all: the previous one is still running"
  else begin
    state.connector_unbind_all_inflight <- true;
    let host = Masc_tui_transport.Workspace_admission.server_peer_host in
    let port = state.port in
    let check_request =
      Masc_tui_transport.Workspace_admission.admission_sequence state ~mailbox
        ~authority ~identity ~host ~port
    in
    let run () =
      let results =
        List.map
          (fun target ->
            let outcome =
              try
                match check_request () with
                | Error refusal ->
                    (* Not sent: the kept-back notice, never a failed
                       unbind (RFC §2). *)
                    Masc_tui_connector_unbind.Kept_back
                      (Masc_tui_types.workspace_refusal_text
                         ~ko:(state.ui_language = Masc_tui_types.Lang_ko)
                         ~request:Masc_tui_words.Kept_request.Connector_unbind
                         refusal)
                | Ok () ->
                    Masc_tui_http.post_connector_unbind_owned ~host ~port target
              with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | exn -> Masc_tui_connector_unbind.Failed (Printexc.to_string exn)
            in
            target, outcome)
          targets
      in
      enqueue_async mailbox
        (Masc_tui_async_protocol.Connectors_msg
           (Masc_tui_async_protocol.Connector_unbind_all_done
              { keeper_name; results }))
    in
    let not_sent detail =
      List.map (fun target -> target, Masc_tui_connector_unbind.Failed detail) targets
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> (
        try
          Masc_tui_transport.Workspace_admission.fork_job state ~mailbox ~sw run
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            enqueue_async mailbox
              (Masc_tui_async_protocol.Connectors_msg
                 (Masc_tui_async_protocol.Connector_unbind_all_done
                    { keeper_name
                    ; results = not_sent (Printexc.to_string exn)
                    })))
    | None ->
        enqueue_async mailbox
          (Masc_tui_async_protocol.Connectors_msg
             (Masc_tui_async_protocol.Connector_unbind_all_done
                { keeper_name; results = not_sent "Eio switch is unavailable" }))
  end

(* The catalog pane's volume GC. A reclaim deletes volumes, so it is an
   operation, and an interruption is answered as "no answer", which the pane
   reads as "may have deleted". A report gets the same receipt so its press
   does not stay running. The MCP session is the one the observer feed
   keeps; without one, this call opens one. *)
let launch_volume_gc (state : Masc_tui_types.state) ~mailbox request =
  let ( let* ) = Result.bind in
  let ( let+ ) x f = Result.map f x in
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  let host = Masc_tui_transport.Workspace_admission.server_peer_host
  and port = state.port
  and session = state.mcp_session in
  let execute = Masc_tui_volume_gc.execute request in
  let deliver result =
    match request with
    | Masc_tui_volume_gc.Report_request ->
        Masc_tui_async_protocol.Tools_msg
          (Masc_tui_async_protocol.Tools_volume_gc_reported result)
    | Masc_tui_volume_gc.Reclaim_request names ->
        Masc_tui_async_protocol.Tools_msg
          (Masc_tui_async_protocol.Tools_volume_gc_reclaimed (names, result))
  in
  state.volume_gc <- Masc_tui_volume_gc.sending state.volume_gc request;
  let failed detail = Masc_tui_types.Request_failed detail in
  Masc_tui_transport.Workspace_admission.launch_guarded_request ~operation:execute
    state ~mailbox ~boundary_error:failed
    ~withdrawn:(fun refusal -> Masc_tui_types.Request_withdrawn refusal)
    ~cancelled:(deliver (Error (failed "interrupted before the server answered")))
    ~deliver
    (fun () ->
      let* session_id =
        match session with
        | Some session_id -> Ok session_id
        | None ->
            Result.map_error failed
              (Masc_tui_http.open_mcp_session ~host ~port
                 ~client_version:Build_version.current)
      in
      let* () =
        Masc_tui_transport.Workspace_admission.admit_request
          ~prior_contact:Masc_tui_server_lifecycle.Server_reached state ~mailbox
          ~authority ~identity ~host ~port ()
        |> Result.map_error (fun refusal ->
               Masc_tui_types.Request_withdrawn refusal)
      in
      let+ outcome =
        Result.map_error failed
          (Masc_tui_http.call_mcp_tool_within
             ~timeout_sec:Masc_tui_volume_gc.timeout_sec ~host ~port ~session_id
             ~request_id:("tui-volume-gc-" ^ Random_id.uuid_v7 ())
             ~tool:Masc_tui_volume_gc.tool
             ~arguments:(Masc_tui_volume_gc.arguments request))
      in
      Masc_tui_volume_gc.answer_of_text ~is_error:outcome.Masc_tui_mcp.is_error
        outcome.Masc_tui_mcp.text)

let press_tools_volume_gc (state : Masc_tui_types.state) ~mailbox =
  match Masc_tui_volume_gc.press state.volume_gc with
  | Masc_tui_volume_gc.Still_running ->
      Masc_tui_loader.report_action state "info"
        "volume GC: the previous request is still running"
  | Masc_tui_volume_gc.Send request -> launch_volume_gc state ~mailbox request

(* The pane draws the answer; the footer says it once. A failure without an
   answer is an error line, since after a reclaim it may hide a deletion. *)
let settle_volume_gc (state : Masc_tui_types.state) request result =
  state.volume_gc <-
    (match result with
     | Ok answer -> Masc_tui_volume_gc.answered answer
     | Error (Masc_tui_types.Request_failed detail) ->
         Masc_tui_volume_gc.unanswered request detail
     | Error (Masc_tui_types.Request_withdrawn refusal) ->
         let named =
           match request with
           | Masc_tui_volume_gc.Report_request ->
               Masc_tui_words.Kept_request.Volume_report
           | Masc_tui_volume_gc.Reclaim_request _ ->
               Masc_tui_words.Kept_request.Volume_reclaim
         in
         Masc_tui_volume_gc.kept_back request
           (Masc_tui_types.workspace_refusal_text
              ~ko:(state.ui_language = Masc_tui_types.Lang_ko)
              ~request:named refusal));
  (* A newly answered report can arm a reclaim. Show its first line before
     the retained report position; periodic inventory reads do not move it. *)
  if
    state.view = Masc_tui_types.Tools
    && Option.is_some
         (Masc_tui_types.tools_volume_gc_parent_scroll state.tools_pane)
  then Masc_tui_types.tools_task_user_scroll state 0;
  let kind =
    match result with
    | Ok (Masc_tui_volume_gc.Report _) -> "system"
    | Ok (Masc_tui_volume_gc.Refused _ | Masc_tui_volume_gc.Unreadable _)
    | Error _ -> "error"
  in
  Masc_tui_loader.report_action state kind
    (Masc_tui_volume_gc.status_line
       ~ko:(state.ui_language = Masc_tui_types.Lang_ko) state.volume_gc)
