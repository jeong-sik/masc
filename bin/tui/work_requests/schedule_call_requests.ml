module T = Masc_tui_types
module P = Masc_tui_async_protocol
module WA = Masc_tui_transport.Workspace_admission
module Keeper_chat_transcript = Masc_tui_keeper_chat_transcript

let launch_schedule_wake_history_load (state : T.state) ~mailbox ~schedule_id =
  if T.server_authority_ready state then begin
    let enqueue_async = WA.workspace_enqueue state in
    match state.schedule_wake_history_inflight with
    | Some inflight when String.equal inflight schedule_id -> ()
    | Some _ | None -> (
        state.schedule_wake_history_inflight <- Some schedule_id;
        let host = WA.server_peer_host in
        let port = state.port in
        let read =
          WA.capture_json_read state (fun () ->
            Masc_tui_loader.load_schedule_wake_history ~host ~port ~schedule_id)
        in
        let run () =
          let result =
            try
              match read () with
              | Error refusal -> Error (T.Request_withdrawn refusal)
              | Ok result ->
                  Result.map_error (fun detail -> T.Request_failed detail) result
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn -> Error (T.Request_failed (Printexc.to_string exn))
          in
          enqueue_async mailbox
            (P.Schedule_msg
               (P.Schedule_wake_history_loaded (schedule_id, result)))
        in
        match Eio_context.get_switch_opt () with
        | Some sw ->
            Eio.Fiber.fork_daemon ~sw (fun () ->
              run ();
              `Stop_daemon)
        | None ->
            enqueue_async mailbox
              (P.Schedule_msg
                 (P.Schedule_wake_history_loaded
                    (schedule_id, Error (T.Request_failed "Eio switch is unavailable")))))
  end

let launch_keeper_schedules_load ?page (state : T.state) ~mailbox ~keeper_name =
  if T.server_authority_ready state then
    let enqueue_async = WA.workspace_enqueue state in
    let navigating = Option.is_some page in
    let page =
      match page with
      | Some page -> page
      | None ->
          if
            state.view = T.Keepers T.Keeper_detail
            && state.detail_tab = T.Detail_automation
          then
            match state.keeper_schedules_page with
            | Some (name, page) when String.equal name keeper_name -> page
            | Some _ | None -> T.schedule_first_page
          else T.schedule_first_page
    in
    (* Tab entry is an explicit read. Reopening supersedes a pending answer,
       while the request ledger retains the original elapsed interval. *)
    let detail =
      T.mark_detail_read_started state ~tab:T.Detail_automation
        ~keeper:keeper_name ~now_ns:(Mtime_clock.elapsed_ns ())
    in
    state.keeper_schedules_pending <- Some (detail, page, state.detail_scroll);
    let request =
      { T.kspr_detail = detail
      ; kspr_page = page
      ; kspr_navigation = navigating
      ; kspr_scroll = state.detail_scroll
      }
    in
    let host = WA.server_peer_host in
    let port = state.port in
    let payload_target = "keeper:" ^ keeper_name in
    WA.launch_guarded_async_read state ~mailbox
      ~source:Masc_tui_async_read.Keeper_schedule
      ~deliver:(fun result ->
        enqueue_async mailbox
          (P.Keeper_msg (P.Keeper_schedules_loaded (request, result))))
      (WA.capture_json_read state (fun () ->
         Masc_tui_loader.load_schedules_for_target ~host ~port ~payload_target
           ~cursor:page.T.sp_cursor))

(* Chat shares the exact target read with Automation. Cadence and entry share
   an in-flight ticket instead of superseding a slow response every tick. *)
let launch_keeper_chat_schedules_load (state : T.state) ~mailbox ~keeper_name =
  if
    state.view = T.Keepers T.Keeper_message
    && state.msg_target_keeper_name = Some keeper_name
    && not
         (T.keeper_schedule_page_pending state ~keeper_name
            T.schedule_first_page)
  then launch_keeper_schedules_load state ~mailbox ~keeper_name

(* An agenda read began, whatever started it: a schedule change announced
   from now on overtakes it ([apply_schedule_agenda_read]), and one announced
   before it is answered by it. *)
let note_schedule_agenda_read_started (state : T.state) =
  state.schedules_agenda_owed <-
    Masc_tui_owed_read.started state.schedules_agenda_owed

let launch_schedules_load ?(intent = T.Snapshot_read.Join) ?page
    (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
    let enqueue_async = WA.workspace_enqueue state in
    let navigating = Option.is_some page in
    let page = Option.value ~default:state.schedules_page page in
    let read, request = T.Snapshot_read.start ~intent state.schedules_read in
    state.schedules_read <- read;
    match request with
    | None -> ()
    | Some ticket ->
        (* As for the agenda: whatever started this page read, it answers the
           changes announced before it. *)
        state.schedules_page_owed <-
          Masc_tui_owed_read.started state.schedules_page_owed;
        let selected_id = T.selected_schedule_id state in
        state.schedules_navigation <-
          (if navigating then Some (ticket, page, selected_id) else None);
        let agenda_ticket =
          if Option.is_some page.T.sp_cursor then None
          else
            let read, ticket =
              T.Snapshot_read.start ~intent state.schedules_agenda_read
            in
            state.schedules_agenda_read <- read;
            if Option.is_some ticket then note_schedule_agenda_read_started state;
            ticket
        in
        let request =
          T.Schedule_page_read
            { T.spr_ticket = ticket
            ; spr_page = page
            ; spr_agenda_ticket = agenda_ticket
            ; spr_navigation = navigating
            ; spr_selected_id = selected_id
            }
        in
        let host = WA.server_peer_host in
        let port = state.port in
        WA.launch_guarded_async_read state ~mailbox
          ~deliver:(fun result ->
            enqueue_async mailbox
              (P.Schedule_msg (P.Schedules_loaded (request, result))))
          (WA.capture_json_read state (fun () ->
             Masc_tui_loader.load_schedules ~host ~port ~cursor:page.T.sp_cursor))
  end

let launch_schedule_agenda_load ?(intent = T.Snapshot_read.Join)
    (state : T.state) ~mailbox =
  if T.server_authority_ready state then begin
    let enqueue_async = WA.workspace_enqueue state in
    let read, request =
      T.Snapshot_read.start ~intent state.schedules_agenda_read
    in
    state.schedules_agenda_read <- read;
    match request with
    | None -> ()
    | Some ticket ->
        note_schedule_agenda_read_started state;
        let host = WA.server_peer_host in
        let port = state.port in
        WA.launch_guarded_async_read state ~mailbox
          ~deliver:(fun result ->
            enqueue_async mailbox
              (P.Schedule_msg
                 (P.Schedules_loaded (T.Schedule_agenda_read ticket, result))))
          (WA.capture_json_read state (fun () ->
             Masc_tui_loader.load_schedules ~host ~port ~cursor:None))
  end

(* The durable call log of one keeper, over HTTP. The row the answer is
   applied to is named in the message so a load that returns after the
   operator moved to another keeper is discarded, not drawn under it. *)
let launch_keeper_calls_load ?(force = false) (state : T.state) ~mailbox
    keeper_name =
  if T.server_authority_ready state then begin
    let same_scope =
      Option.equal String.equal state.keeper_calls_keeper (Some keeper_name)
    in
    if state.keeper_calls_loading && same_scope then begin
      if force then state.keeper_calls_refresh_pending <- true
    end
    else begin
      state.keeper_calls_generation <- state.keeper_calls_generation + 1;
      let generation = state.keeper_calls_generation in
      if not same_scope then state.keeper_calls <- None;
      state.keeper_calls_keeper <- Some keeper_name;
      state.keeper_calls_loading <- true;
      state.keeper_calls_refresh_pending <- false;
      (* A retry has not repaired the previous read failure yet. Keep that
         observation until a successful response replaces it. *)
      if not same_scope then state.keeper_calls_error <- None;
      let host = WA.server_peer_host in
      let port = state.port in
      WA.launch_json_read state ~mailbox
        ~boundary_error:(fun detail -> T.Request_failed detail)
        ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
        ~deliver:(fun result ->
          P.Keeper_msg
            (P.Keeper_calls_loaded (generation, keeper_name, result)))
        (fun () ->
          Masc_tui_http.fetch_keeper_calls ~host ~port ~keeper_name ~limit:100
          |> Result.map_error (fun detail -> T.Request_failed detail))
    end
  end

let cancel_chat_call_pending (state : T.state) =
  Option.iter
    (fun (request : T.chat_call_request) ->
      Masc_tui_workspace_job.cancel_observation state ~key:request.T.ccr_job)
    state.chat_call_pending;
  state.chat_call_pending <- None

let close_chat_call_reader (state : T.state) =
  cancel_chat_call_pending state;
  state.chat_call_reader <- None

let launch_chat_call_read (state : T.state) ~mailbox =
  cancel_chat_call_pending state;
  Option.iter
    (fun (request : T.chat_call_request) ->
      let host = WA.server_peer_host and port = state.port in
      let execution_id = Masc_tui_fetched.request_key request.T.ccr_ticket in
      WA.launch_json_read ~key:request.T.ccr_job state ~mailbox
        ~boundary_error:(fun detail -> T.Request_failed detail)
        ~withdrawn:(fun refusal -> T.Request_withdrawn refusal)
        ~deliver:(fun result -> P.Chat_msg (P.Chat_call_loaded (request, result)))
        (fun () ->
          Masc_tui_http.fetch_keeper_call ~host ~port
            ~keeper_name:request.T.ccr_origin.T.cco_keeper ~execution_id
          |> Result.map_error (fun detail -> T.Request_failed detail)))
    (T.begin_chat_call_read state)

let open_chat_call_reader ?execution_id (state : T.state) ~mailbox keeper_name =
  if
    state.view = T.Keepers T.Keeper_message
    && Option.equal String.equal state.msg_target_keeper_name (Some keeper_name)
    && T.server_authority_ready state
  then
    match state.server_identity with
    | None -> ()
    | Some cco_workspace ->
        let from_rows =
          T.chat_rows_for state keeper_name
          |> List.concat_map (fun (row : T.msg_entry) ->
               match row.T.me_tool_block with
               | Some block -> block.Keeper_chat_transcript.activities
               | None -> [])
        in
        let live =
          T.selected_source_logs_for_keeper state keeper_name
          |> List.concat_map (fun (log : T.turn_log) ->
               Keeper_chat_transcript.tool_calls log.T.tl_transcript)
        in
        let choices =
          List.filter_map
            (fun (activity : Keeper_chat_transcript.tool_activity) ->
              Option.map
                (fun execution_id ->
                  { Masc_tui_chat_call_reader.execution_id
                  ; tool = activity.Keeper_chat_transcript.tool_name
                  ; args = activity.Keeper_chat_transcript.args
                  ; subject = activity.Keeper_chat_transcript.subject
                  })
                activity.Keeper_chat_transcript.execution_id)
            (from_rows @ live)
        in
        let reader =
          Masc_tui_chat_call_reader.create ~ko:(state.ui_language = T.Lang_ko)
            (List.rev choices)
        in
        let selected =
          match execution_id with
          | None -> Some reader
          | Some id -> Masc_tui_chat_call_reader.select_execution id reader
        in
        Option.iter
          (fun reader ->
            close_chat_call_reader state;
            let origin =
              { T.cco_workspace
              ; cco_keeper = keeper_name
              ; cco_authority = state.workspace_authority
              ; cco_reading = state.workspace_read_authority
              }
            in
            state.chat_call_reader <- Some (origin, reader);
            if Option.is_some execution_id then
              launch_chat_call_read state ~mailbox)
          selected
