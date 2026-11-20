(** Keeper chat navigation, copy-reply read, journal / operation reads,
    runtime catalog loading, and Context Inspector reads. *)

module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Kept_request = Masc_tui_words.Kept_request
module Context_results = Masc_tui_context_results
module Keeper_chat = Masc_tui_keeper_chat_projection
module Keeper_chat_log = Masc_tui_keeper_chat_log
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript

let enter_keeper_chat ?(return_to = T.Keeper_chat_return_detail) (state : T.state)
    ~keeper_name ~drain_queue ~load_history =
  if T.keeper_available_for_new_message state keeper_name then begin
    Masc_tui_chat_input.Message_draft_recall.open_message_for_keeper ~return_to state keeper_name ~drain_queue;
    state.view <- T.Keepers T.Keeper_message;
    load_history keeper_name
  end else
    Masc_tui_loader.report_action state "error"
      "Chat requires a matching workspace and a current Keeper roster"

let prepare_item_request (state : T.state) ~drain_queue ~load_history =
  match T.selected_keeper state, T.selected_browser_item state with
  | Some (keeper : Masc.Tui_decode.keeper), Some item ->
    (match Masc_tui_keeper_items.request ~account:(T.selected_item_account state)
             ~balance_milli:(T.selected_item_balance_now state) item with
     | Error reason -> Masc_tui_loader.report_action state "error" reason
     | Ok request ->
       if Option.is_some (T.recall_edit_for_keeper state keeper.Masc.Tui_decode.k_name) then
         Masc_tui_loader.report_action state "info" "Item request not prepared; queued edit retained."
       else begin
         enter_keeper_chat state ~keeper_name:keeper.Masc.Tui_decode.k_name ~drain_queue ~load_history;
         if state.view = T.Keepers T.Keeper_message
            && state.msg_target_keeper_name = Some keeper.Masc.Tui_decode.k_name then
           if Option.is_some (T.current_recall_edit state) then
             Masc_tui_loader.report_action state "info" "Item request not prepared; queued edit retained."
           else if T.keeper_message_draft_empty state then
             Masc_tui_chat_input.Message_draft_recall.set_composer_text state (Masc_tui_keeper_items.request_draft request)
           else Masc_tui_loader.report_action state "info"
             "Your existing chat draft is preserved. Send or save it before preparing an Item request."
       end)
  | (Some _ | None), None | None, Some _ ->
    Masc_tui_loader.report_action state "info" "Select an item before preparing a Keeper request"

(* Copy reads the stored reply again, before the display layer scrubs control
   bytes or wraps lines. A separate read leaves the visible history cache and
   its pagination untouched. *)
let settle_retired_chat_copy (state : T.state) =
  match state.msg_copy_pending with
  | Some (generation, keeper_name, reading) when reading != state.workspace_read_authority ->
      state.msg_copy_pending <- None;
      if generation = state.msg_copy_generation
         && state.msg_target_keeper_name = Some keeper_name then
        Masc_tui_loader.report_action state "error"
          "/copy was interrupted by workspace reconnection; retry after reconnecting"
  | Some _ | None -> ()

let launch_keeper_chat_copy (state : T.state) ~mailbox ~keeper_name =
  if not (T.server_authority_ready state) then
    Masc_tui_loader.report_action state "error" (Request_notice.kept_back_until_reconnect ~ko:(state.ui_language = T.Lang_ko)
      ~request:(Masc_tui_words.Kept_request.Command "/copy"))
  else begin
  let enqueue_async = Admission.workspace_enqueue state in
  state.msg_copy_generation <- state.msg_copy_generation + 1;
  let generation = state.msg_copy_generation in
  state.msg_copy_pending <- Some (generation, keeper_name, state.workspace_read_authority);
  let host = Admission.server_peer_host in
  let port = state.port in
  Admission.launch_async_read state ~mailbox
    ~deliver:(fun result ->
      enqueue_async mailbox (P.Keeper_msg (P.Keeper_chat_copy_loaded (generation, keeper_name, result))))
    (fun () -> Masc_tui_http.fetch_keeper_chat_history ~host ~port ~keeper_name)
  end
;;

(* The guard's refusal stays apart from the read's own failure: a read it
   stopped was not sent (RFC §2). *)
let read_keeper_chat_operation ~check_request ~host ~port
    ~keeper_name ~operation_id =
  try
    let open Result.Syntax in
    let* () = check_request () |> Result.map_error (fun refusal -> T.Request_withdrawn refusal) in
    let failed result = Result.map_error (fun detail -> T.Request_failed detail) result in
    let path = Printf.sprintf "/api/v1/keepers/%s/chat/operations/%s"
      (Masc_tui_http.percent_encode_path_segment keeper_name)
      (Masc_tui_http.percent_encode_path_segment operation_id) in
    let* json = failed (Masc_tui_http.get_json ~host ~port ~path) in
    failed (Keeper_chat_log.decode_operation_state ~operation_id json)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (T.Request_failed (Printexc.to_string exn))
;;

let apply_keeper_chat_operation_state (state : T.state) ~journal_id (log : T.turn_log) = function
  | Ok observed ->
      Keeper_chat_log.observe_operation_state log.tl_log observed;
      Option.iter (Keeper_chat_transcript.reconcile_operation log.tl_transcript)
        (Keeper_chat_log.operation_state log.tl_log)
  | Error (T.Request_failed detail) ->
      Keeper_chat_log.observe_operation_state log.tl_log None;
      Masc_tui_loader.add_event state "error"
        (Printf.sprintf "operation for %s not loaded: %s"
           (Keeper_chat.compact_request_id journal_id)
           (Keeper_chat.terminal_safe_text detail))
  | Error (T.Request_withdrawn refusal) ->
      Keeper_chat_log.observe_operation_state log.tl_log None;
      Masc_tui_loader.add_event state "error"
        (T.workspace_refusal_text ~ko:(state.ui_language = T.Lang_ko)
           ~request:Masc_tui_words.Kept_request.Keeper_operation_read refusal
         ^ " · " ^ Keeper_chat.compact_request_id journal_id)
;;

let launch_keeper_chat_operation_reads (state : T.state) ~mailbox ~keeper_name targets =
  match targets, Eio_context.get_switch_opt () with
  | [], (Some _ | None) | _ :: _, None -> ()
  | _ :: _, Some sw ->
      let enqueue_async = Admission.workspace_enqueue state in
      let host = Admission.server_peer_host and port = state.port in
      let check_request = Admission.capture_admission state ~mailbox in
      List.iter (fun operation_id ->
        T.journal_read_started state (keeper_name, Keeper_chat_log.Operation operation_id)) targets;
      Admission.fork_job ~kind:Masc_tui_workspace_precondition.Observation state ~mailbox ~sw (fun () ->
        List.iter (fun operation_id ->
          let operation_state = read_keeper_chat_operation ~check_request ~host ~port
            ~keeper_name ~operation_id in
          enqueue_async mailbox
            (P.Keeper_msg (P.Keeper_chat_operation_loaded {keeper_name; operation_id; operation_state}))) targets)
;;

let launch_unavailable_journal_operations (state : T.state) ~mailbox ~keeper_name =
  launch_keeper_chat_operation_reads state ~mailbox ~keeper_name
    (T.unavailable_journal_operation_targets state keeper_name)
;;

let launch_selected_preparation_operation_read (state : T.state) ~mailbox =
  if T.server_authority_ready state then
    match state.msg_target_keeper_name with
    | None -> ()
    | Some keeper_name ->
      launch_keeper_chat_operation_reads state ~mailbox ~keeper_name
        (T.keeper_message_preparation_operation_targets state ~keeper_name)
;;

(* One fiber per load, reading the journals one after another in the order
   the targets came -- newest turn first -- each from where the session's
   record of it ends, and handing each turn's lines to the mailbox as they
   land; the handler folds them. Reading them in turn rather than all at once
   is what bounds the requests in flight: a load holds one read open whatever
   the page named, so a history window full of turns the session does not
   hold is not a burst of connections to the server. Every target is marked
   in flight before the fiber starts, so a load that arrives meanwhile does
   not queue a second read of a turn this one has not reached yet; the mark
   clears as each result is handled. A read that starts late may find its
   turn grown since the targets were chosen: the position it resumes from was
   taken then, and the log's seq dedup drops what the live stream has
   meanwhile added. Failures are typed by the fetch and decided in the
   handler, not here. *)
let launch_keeper_chat_journal_loads ?(follow = false) (state : T.state) ~mailbox ~keeper_name targets =
  if T.server_authority_ready state then begin
  let enqueue_async = Admission.workspace_enqueue state in
  let authority = state.workspace_authority in
  let identity = state.server_identity in
  let host = Admission.server_peer_host in
  let port = state.port in
  let check_request = Admission.admission_sequence state ~mailbox ~authority ~identity ~host ~port in
  let run (source, started_at, since_seq) =
    (* The journal can lack its final event after interruption or an append
       failure. Its cursor remains the journal's; the exact operation is a
       separate authority for whether that execution is still running. Read
       it first: terminal store settlement follows the final journal append,
       so the following journal read cannot cut off that terminal prefix. *)
    let read_operation () =
      match source with
      | Keeper_chat_log.Autonomous_turn _ -> Ok None
      | Keeper_chat_log.Operation operation_id ->
          read_keeper_chat_operation ~check_request ~host ~port
            ~keeper_name ~operation_id |> Result.map Option.some
    in
    let turn_state = ref None in
    let read_journal () =
      try
        Keeper_chat_log.read_whole_journal ~since_seq
          ~fetch:(fun ~since_seq ~since_offset ->
            (* Pages at the journal's own ceiling: one definition, the
               server's and this client's, so the ask can never exceed
               what the endpoint admits. *)
            match check_request () with
            | Error refusal ->
              Error (Keeper_chat_log.Events_kept_back
                (T.workspace_refusal_text ~ko:(state.ui_language = T.Lang_ko)
                   ~request:Masc_tui_words.Kept_request.Keeper_journal_read refusal))
            | Ok () ->
                let page = Masc_tui_http.fetch_keeper_chat_events ~host ~port ~keeper_name
                    ~source ~since_seq ~since_offset ~follow
                    ~limit:Masc.Keeper_chat_event_log.page_max_limit in
                Result.iter (fun (page : Keeper_chat_log.events_page) ->
                  turn_state := page.turn_state) page;
                page)
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Keeper_chat_log.Events_transport (Printexc.to_string exn))
    in
    let operation_state, journal, terminal_replay = Keeper_chat_log.read_with_operation_state
      ~read_operation ~read_journal in
    enqueue_async mailbox
      (P.Keeper_msg (P.Keeper_chat_journal_loaded { keeper_name; source; started_at; turn_state = !turn_state;
                                                 journal; operation_state; terminal_replay }))
  in
  match targets, Eio_context.get_switch_opt () with
  | [], Some _ | [], None -> ()
  | _ :: _, Some sw ->
      List.iter
        (fun (source, _, _) -> T.journal_read_started state (keeper_name, source))
        targets;
      Admission.fork_job ~kind:Masc_tui_workspace_precondition.Observation state ~mailbox ~sw (fun () -> List.iter run targets)
  | _ :: _, None ->
      (* No switch, no fetch: the v1 rows stay, and nothing is
         remembered, so a later load with a switch asks. *)
      ()
  end

let launch_current_autonomous_journals (state : T.state) ~mailbox ~keeper_name =
  T.autonomous_journal_candidates ~keeper_name state.keeper_turns
  |> List.iter (fun (source, at) ->
      let key = keeper_name, source in
      match T.journal_follow_for_source state ~keeper_name ~source ~seq:None ~at with
      | T.Follow_nothing -> ()
      | T.Follow_read_after_inflight -> T.journal_read_wanted state key None
      | T.Follow_read {started_at; since_seq} ->
          launch_keeper_chat_journal_loads state ~mailbox ~keeper_name [source, started_at, since_seq])

let launch_runtime_catalog_load ?(intent = T.Snapshot_read.Join) (state : T.state) ~mailbox =
  match T.begin_runtime_catalog_read state ~intent ~started_ns:(Mtime_clock.elapsed_ns ()) with
  | None ->
      Log.Transport.info "tui_runtime_catalog phase=shared_or_deferred followup=%b resume=%b"
        (T.Local_read_order.has_followup state.runtime_catalog_order) state.runtime_catalog_resume
  | Some request ->
      let enqueue_async = Admission.workspace_enqueue state in
      let host = Admission.server_peer_host and port = state.port in
      let id = T.Local_read_order.request_id request.T.rcr_request in
      let publish result =
        Log.Transport.info "tui_runtime_catalog request=%d started_ns=%Ld observed_ns=%Ld phase=%s"
          id request.T.rcr_started_ns (Mtime_clock.elapsed_ns ())
          (match result with Ok _ -> "received" | Error _ -> "failed");
        enqueue_async mailbox (P.Runtime_msg (P.Runtime_catalog_loaded (request,result))) in
      let run () =
        let result = try
          if T.runtime_catalog_request_current state request then Masc_tui_loader.load_runtime_resolved ~host ~port
          else Error "Runtime catalogue read authority withdrew before dispatch"
        with
        | Eio.Cancel.Cancelled _ as exn ->
            Log.Transport.info "tui_runtime_catalog request=%d started_ns=%Ld observed_ns=%Ld phase=interrupted"
              id request.T.rcr_started_ns (Mtime_clock.elapsed_ns ()); raise exn
        | exn -> Error (Printexc.to_string exn) in
        publish result in
      Log.Transport.info "tui_runtime_catalog request=%d started_ns=%Ld revision=%s phase=started"
        id request.T.rcr_started_ns (T.Local_read_order.revision_to_string (T.Local_read_order.request_revision request.T.rcr_request));
      (match Eio_context.get_switch_opt () with
       | None -> publish (Error "Eio switch is unavailable")
       | Some sw ->
           (match Admission.fork_job ~observation:true
             ~on_withdrawn:(fun () -> publish (Error "Runtime catalogue workspace withdrew before worker entry"))
             state ~mailbox ~sw run with
            | () -> ()
            | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
            | exception exn -> publish (Error (Printexc.to_string exn))))

let launch_context_inspector_load ?forecast ?(reuse = false) (state : T.state) ~mailbox ~keeper_name =
  if T.server_authority_ready state then begin
  let deliver = Admission.deliver_context state mailbox in
  let host = Admission.server_peer_host in
  let port = state.port in
  let tab = state.context_inspector_tab in
  let previous = T.begin_context_inspector_read ~reuse state ~keeper_name in
  let generation = state.context_inspector_generation in
  let target = state.context_inspector_target in
  let run () =
    let publish reading =
      deliver (Masc_tui_context_results.Context_inspector_loaded (generation, keeper_name, reading))
    in
    try
      match target with
      | Masc_tui_context_inspector.Recent turn_back ->
          Masc_tui_http.fetch_keeper_context_inspector ~forecast ~previous ~tab ~host ~port
            ~keeper_name ~turn_back ~publish
      | Masc_tui_context_inspector.Pinned turn_ref ->
          Masc_tui_http.fetch_keeper_exact_context_inspector
            ~host ~port ~keeper_name ~turn_ref ~previous ~tab ~publish
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> publish (Masc_tui_context_inspector.Request_failed (Printexc.to_string exn))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      (* The replaced read is cancelled where it waits, which closes its
         connection; its answer was already discarded by generation, and the
         server stops writing a body nobody reads. *)
      let superseded, supersede = Eio.Promise.create () in
      T.supersede_context_inspector_load state
        (* fire-and-forget: the bool try_resolve returns (already resolved?) is not needed. *)
        (Some (fun () -> ignore (Eio.Promise.try_resolve supersede ())));
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Fiber.first
            (fun () -> run ())
            (fun () -> Eio.Promise.await superseded);
          `Stop_daemon)
  | None ->
      deliver
        (Masc_tui_context_results.Context_inspector_loaded
           ( generation
           , keeper_name
           , Masc_tui_context_inspector.Request_failed
               "Eio switch is unavailable" ))
  end

let launch_context_inspector_part_load (state : T.state) ~mailbox request =
  let deliver = Admission.deliver_context state mailbox in
  let host = Admission.server_peer_host in
  let port = state.port in
  let key = Masc_tui_fetched.request_key request in
  T.supersede_context_inspector_part_load state None;
  let run () =
    let result =
      try Masc_tui_http.fetch_provider_input_part ~host ~port key with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Printexc.to_string exn)
    in
    deliver (Masc_tui_context_results.Context_inspector_part_loaded (request, result))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      (* Holding j steps through parts faster than they answer; each step
         stops the read before it where it waits, as a turn step does. *)
      let superseded, supersede = Eio.Promise.create () in
      T.supersede_context_inspector_part_load state
        (* fire-and-forget: the bool try_resolve returns (already resolved?) is not needed. *)
        (Some (fun () -> ignore (Eio.Promise.try_resolve supersede ())));
      Eio.Fiber.fork_daemon ~sw (fun () ->
          Eio.Fiber.first
            (fun () -> run ())
            (fun () -> Eio.Promise.await superseded);
          `Stop_daemon)
  | None ->
      deliver
        (Masc_tui_context_results.Context_inspector_part_loaded
           (request, Error "Eio switch is unavailable"))

(* Runs once per loop pass. The tab requests only its missing source, and
   withdraws another tab's pending source before beginning a new generation.
   The pane then names the part it shows; when that is not the part held,
   the held one's read stops and the shown one is read.
   Asking here rather than in each key handler keeps every way the cursor,
   the tab or the reading can change on one path. *)
let reconcile_context_inspector_part (state : T.state) ~mailbox =
  if state.context_inspector_open && T.server_authority_ready state then
    match
      ( state.context_inspector_reading
      , state.context_inspector_keeper )
    with
    | Some (keeper, reading), Some open_keeper
      when String.equal keeper open_keeper ->
        if Masc_tui_context_inspector.needs_tab_read
             ~tab:state.context_inspector_tab reading then
          launch_context_inspector_load ~reuse:true state ~mailbox ~keeper_name:keeper;
        (match
           Masc_tui_context_inspector.shown_part ~keeper
             ~tab:state.context_inspector_tab
             ~target:state.context_inspector_target
             ~opened:state.context_inspector_exact
             ~cursor:state.context_inspector_cursor reading
         with
         | None -> ()
         | Some key ->
             let equal = Masc_tui_context_inspector.same_part_key in
             (match Masc_tui_fetched.current_key state.context_inspector_part with
              | Some held when equal held key -> ()
              | Some _ | None ->
                  (match
                     Masc_tui_fetched.start ~equal state.context_inspector_part ~key
                   with
                   | Masc_tui_fetched.Already_loading -> ()
                   | Masc_tui_fetched.Started (next, request) ->
                       state.context_inspector_part <- next;
                       launch_context_inspector_part_load state ~mailbox request)))
    | Some _, (Some _ | None) | None, (Some _ | None) -> ()

let open_context_inspector ?(target = Masc_tui_context_inspector.Recent 0) (state : T.state) ~mailbox ~keeper_name =
  (match target with
   | Masc_tui_context_inspector.Recent _ -> launch_runtime_catalog_load state ~mailbox
   | Masc_tui_context_inspector.Pinned _ -> ());
  state.context_inspector_open <- true;
  state.context_inspector_keeper <- Some keeper_name;
  (* A fresh Keeper target starts unread. Showing the previous Keeper's
     already-loaded composition under this name while the GET is in flight
     would misattribute its input while the GET is in flight. Each open
     starts unread; pinned refreshes also start a fresh observation generation. *)
  state.context_inspector_reading <- None;
  state.context_inspector_read_at <- None;
  state.context_inspector_tab <-
    (match target with
     | Masc_tui_context_inspector.Recent _ -> Masc_tui_context_inspector.Composition
     | Masc_tui_context_inspector.Pinned _ -> Masc_tui_context_inspector.Exact_input);
  state.context_inspector_response_return <- state.context_inspector_tab;
  state.context_inspector_response_scroll <- 0;
  state.context_inspector_cursor <- 0;
  state.context_inspector_scroll <- 0;
  state.context_inspector_exact <- None;
  T.supersede_context_inspector_part_load state None;
  state.context_inspector_part <- Masc_tui_fetched.clear state.context_inspector_part;
  state.context_inspector_detail_scroll <- 0;
  state.context_inspector_target <- target;
  launch_context_inspector_load state ~mailbox ~keeper_name

let switch_to_next_keeper_message (state : T.state) ~drain_queue ~load_history =
  match T.next_keeper_message_target state with
  | Masc_tui_keeper_selection.No_alternative -> ()
  | Masc_tui_keeper_selection.Switch_to { keeper_name; cursor } ->
      Masc_tui_chat_input.Message_draft_recall.open_message_for_keeper ~return_to:state.msg_return state keeper_name
        ~drain_queue;
      state.keeper_cursor <- cursor;
      T.set_msg_scroll state 0;
      load_history keeper_name
