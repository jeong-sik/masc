module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Owed_read = Masc_tui_owed_read
module Mono = Masc_tui_wake.Mono
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Keeper_chat_history = Masc_tui_keeper_chat_history
module Tui_decode = Masc.Tui_decode

let launch_keeper_older_page (state : T.state) ~mailbox ~keeper_name ~cursor =
  if T.server_authority_ready state then begin
  Masc_tui_frame_timing.time_stage ~name:"chat.older.requested" (fun () -> ());
  (* Explicit/resumed paging owns the cursor from here. A still-running cold
     first page must not later rewind it, even if both requested [None]. *)
  (match state.T.msg_history_inflight with
   | Some request when String.equal (T.Keeper_history_read.keeper request) keeper_name ->
       T.Keeper_history_read.retire_page request;
       if not (T.Keeper_history_read.pending request) then state.T.msg_history_inflight <- None
   | Some _ | None -> ());
  let enqueue_async = Admission.workspace_enqueue state in
  let host = Admission.server_peer_host in
  let port = state.T.port in
  let generation = state.T.msg_history_load_generation in
  state.T.msg_older_loading <- true;
  let run () =
    let result =
      try
        Masc_tui_http.fetch_keeper_chat_history_page ~host ~port ~keeper_name
          ~cursor
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (Keeper_chat_history.Page_read_failed (Printexc.to_string exn))
    in
    enqueue_async mailbox
      (P.Keeper_msg (P.Keeper_chat_older_loaded (generation, keeper_name, cursor, result)))
  in
  match Eio_context.get_switch_opt () with
  | Some sw ->
      Eio.Fiber.fork_daemon ~sw (fun () ->
          run ();
          `Stop_daemon)
  | None ->
      enqueue_async mailbox
        (P.Keeper_msg (P.Keeper_chat_older_loaded
           (generation, keeper_name, cursor, Error (Keeper_chat_history.Page_read_failed "Eio switch is unavailable"))))
  end

let launch_keeper_native_tasks_load ?(mode=Masc_tui_native_tasks.Suffix) (state : T.state) ~mailbox ~keeper_name =
  let eligible = T.server_authority_ready state in
  if mode=Masc_tui_native_tasks.Audit
     && not (List.mem keeper_name state.T.msg_native_tasks_audit_pending) then
    state.T.msg_native_tasks_audit_pending <- keeper_name :: state.T.msg_native_tasks_audit_pending;
  if eligible && not (List.mem_assoc keeper_name state.T.msg_native_tasks_inflight) then begin
    let mode = if List.mem keeper_name state.T.msg_native_tasks_audit_pending
      then Masc_tui_native_tasks.Audit else mode in
    state.T.msg_native_tasks_audit_pending <-
      List.filter ((<>) keeper_name) state.T.msg_native_tasks_audit_pending;
    let enqueue_async = Admission.workspace_enqueue state in
    let authority = state.T.workspace_authority in
    let identity = state.T.server_identity in
    let host = Admission.server_peer_host and port = state.T.port in
    let previous = Option.value ~default:Masc_tui_native_tasks.empty
        (List.assoc_opt keeper_name state.T.msg_native_tasks) in
    state.T.msg_native_tasks_inflight <- (keeper_name,mode) :: state.T.msg_native_tasks_inflight;
    let read_authority = state.T.workspace_read_authority in
    Admission.launch_async_read_with state ~mailbox
      ~boundary_error:(fun detail -> Masc_tui_native_tasks.Transport detail)
      ~withdrawn:(fun refusal -> Masc_tui_native_tasks.Kept_back
        (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
          ~request:T.Kept_request.Native_tasks_read refusal))
      ~deliver:(fun result -> enqueue_async mailbox (P.Keeper_msg (P.Keeper_native_tasks_loaded (keeper_name,result))))
      (fun () -> Masc_tui_native_tasks.read ~mode ~keeper_name ~previous
        ~fetch:(fun path ->
          let open Result.Syntax in
          let retired () = if read_authority == state.T.workspace_read_authority then Ok ()
            else Error (Masc_tui_native_tasks.Transport "workspace observation read was retired") in
          (* The guard's refusal is the kept-back notice, never a transport
             failure (RFC §2). *)
          let admit () = Admission.admit_request state ~mailbox ~authority ~identity ~host ~port () in
          let* () = retired () in
          let* () = admit () |> Result.map_error (fun refusal -> Masc_tui_native_tasks.Kept_back
            (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
              ~request:T.Kept_request.Native_tasks_read refusal)) in
          let result = Masc_tui_http.http_get ~host ~port ~path
            |> Result.map_error (fun detail -> Masc_tui_native_tasks.Transport detail) in
          let* () = retired () in
          let* () = admit () |> Result.map_error (fun refusal -> Masc_tui_native_tasks.Transport
            (Request_notice.workspace_response_refusal_text state ~request:T.Kept_request.Native_tasks_read refusal)) in
          result))
  end

let launch_keeper_child_content_load ?(mode=Masc_tui_child_content.Suffix) (state : T.state) ~mailbox ~keeper_name =
  (* Reading retained server observations does not submit a message or use
     local attachment paths. Remote/missing roster rows are not a refusal. *)
  let eligible = T.server_authority_ready state in
  (* An explicit Audit is retained intent even while reading is unconfirmed;
     it does not authorize an HTTP request. Workspace withdrawal clears it. *)
  let audit_running = match List.assoc_opt keeper_name state.T.msg_child_content_inflight with
    | Some Masc_tui_child_content.Audit -> true
    | None | Some Masc_tui_child_content.Suffix -> false in
  if mode=Masc_tui_child_content.Audit && not audit_running
     && not (List.mem keeper_name state.T.msg_child_content_audit_pending) then
    state.T.msg_child_content_audit_pending <- keeper_name :: state.T.msg_child_content_audit_pending;
  if eligible && not (List.mem_assoc keeper_name state.T.msg_child_content_inflight) then begin
    let mode = if List.mem keeper_name state.T.msg_child_content_audit_pending
      then Masc_tui_child_content.Audit else mode in
    state.T.msg_child_content_audit_pending <-
      List.filter ((<>) keeper_name) state.T.msg_child_content_audit_pending;
    let enqueue_async = Admission.workspace_enqueue state in
    let authority = state.T.workspace_authority in
    let identity = state.T.server_identity in
    let reading = state.T.workspace_read_authority in
    let host = Admission.server_peer_host and port = state.T.port in
    let previous = Option.value ~default:Masc_tui_child_content.empty
        (List.assoc_opt keeper_name state.T.msg_child_content) in
    state.T.msg_child_content_inflight <- (keeper_name,mode) :: state.T.msg_child_content_inflight;
    Admission.launch_async_read_with state ~mailbox
      ~boundary_error:(fun detail -> Masc_tui_child_content.Transport detail)
      ~withdrawn:(fun refusal -> Masc_tui_child_content.Kept_back
        (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
          ~request:T.Kept_request.Child_content_read refusal))
      ~deliver:(fun result -> enqueue_async mailbox (P.Keeper_msg (P.Keeper_child_content_loaded (keeper_name,result))))
      (fun () -> Masc_tui_child_content.read ~mode ~keeper_name ~previous
        ~fetch:(fun path ->
          let open Result.Syntax in
          (* The guard's refusal is the kept-back notice, never a transport
             failure (RFC §2). *)
          let retired () =
            if reading != state.T.workspace_read_authority then
              Error (Masc_tui_child_content.Transport "Child observation read was retired")
            else Ok () in
          let admit () = Admission.admit_request state ~mailbox ~authority ~identity ~host ~port () in
          let* () = retired () in
          let* () = admit () |> Result.map_error (fun refusal -> Masc_tui_child_content.Kept_back
            (T.workspace_refusal_text ~ko:(state.T.ui_language = T.Lang_ko)
              ~request:T.Kept_request.Child_content_read refusal)) in
          let result = Masc_tui_http.http_get ~host ~port ~path
            |> Result.map_error (fun detail -> Masc_tui_child_content.Transport detail) in
          let* () = retired () in
          let* () = admit () |> Result.map_error (fun refusal -> Masc_tui_child_content.Transport
            (Request_notice.workspace_response_refusal_text state ~request:T.Kept_request.Child_content_read refusal)) in
          result))
  end

(* The owed history read of [keeper_name] under the current workspace
   reading, when the record is theirs. *)
let current_history_owed (state : T.state) ~keeper_name =
  match state.T.msg_history_owed with
  | Some owed
    when String.equal owed.T.kho_keeper keeper_name
         && owed.T.kho_authority = state.T.workspace_authority
         && owed.T.kho_reading == state.T.workspace_read_authority ->
      Some owed
  | Some _ | None -> None

(* Move the owed history read of [keeper_name]. A record of another Keeper or
   reading is replaced. [audit] is kept until a forced read starts. *)
let update_history_owed ?(audit = false) (state : T.state) ~keeper_name transition =
  let owed =
    match current_history_owed state ~keeper_name with
    | Some owed -> owed
    | None ->
        { T.kho_keeper = keeper_name
        ; kho_authority = state.T.workspace_authority
        ; kho_reading = state.T.workspace_read_authority
        ; kho_read = Owed_read.settled
        ; kho_audit = false }
  in
  state.T.msg_history_owed <-
    Some { owed with kho_read = transition owed.T.kho_read; kho_audit = owed.T.kho_audit || audit }

let launch_keeper_history_load ?(load_file_changes = true) ?(force = false) (state : T.state) ~mailbox
    ~keeper_name =
  let other_page_pending = match state.T.keeper_schedules_pending with
    | Some (request, page, _) when String.equal request.T.drr_keeper keeper_name
                                && Option.is_some page.T.sp_cursor ->
        T.keeper_schedule_page_pending state ~keeper_name page
    | Some _ | None -> false in
  if force || other_page_pending || not (T.keeper_schedule_first_page_available state keeper_name) then
    Masc_tui_work_requests.Schedule_call_requests.launch_keeper_chat_schedules_load state ~mailbox ~keeper_name;
  if force then state.T.msg_preparation_details <-
    Masc_tui_preparation_details.refresh ~keeper_name state.T.msg_preparation_details;
  launch_keeper_child_content_load
    ~mode:(if force then Masc_tui_child_content.Audit else Masc_tui_child_content.Suffix)
    state ~mailbox ~keeper_name;
  launch_keeper_native_tasks_load
    ~mode:(if force then Masc_tui_native_tasks.Audit else Masc_tui_native_tasks.Suffix)
    state ~mailbox ~keeper_name;
  if T.server_authority_ready state then begin
  let identity = state.T.server_identity in
  let authority = state.T.workspace_authority in
  if T.keeper_available_for_new_message state keeper_name then begin
  let already_inflight =
    match state.T.msg_history_inflight with
    | Some request -> String.equal (T.Keeper_history_read.keeper request) keeper_name
    | None -> false
  in
  (* Joined or started below, a read of this Keeper is on the wire. *)
  T.note_chat_entry_read state ~keeper_name;
  if already_inflight && not force then ()
  else begin
    (* An unforced read cannot settle an owed audit: the audit stays owed and
       runs once this read lands. *)
    (match current_history_owed state ~keeper_name with
     | Some owed when owed.T.kho_audit && not force -> ()
     | Some _ | None ->
         update_history_owed state ~keeper_name Owed_read.started;
         Option.iter
           (fun owed -> state.T.msg_history_owed <- Some { owed with kho_audit = false })
           state.T.msg_history_owed);
    let host = Admission.server_peer_host in
    let port = state.T.port in
    state.T.msg_history_load_generation <- state.T.msg_history_load_generation + 1;
    let first_page = state.T.msg_loaded_keeper <> Some keeper_name
      || not (T.keeper_chat_history_received state.T.msg_loaded_sources.T.kcs_history) in
    state.T.msg_older_loading <- first_page;
    let request = T.Keeper_history_read.create
      ~generation:state.T.msg_history_load_generation ~keeper:keeper_name
      ~authority ~reading:state.T.workspace_read_authority ~first_page in
    state.T.msg_history_inflight <- Some request;
    let publish source result =
      T.Keeper_history_read.publish request source
        ~ready_at_ns:(Mtime_clock.elapsed_ns ()) result in
    let read source fetch =
      (* Each source keeps its own identity-probe chain. Neither result waits
         for its sibling or for capacity in the shared mailbox. *)
      (* The guard's refusal stays typed apart from the read's own failure,
         so the pane draws it as kept back (RFC §2). *)
      let check_request = Admission.admission_sequence state ~mailbox ~authority ~identity ~host ~port in
      let request = match source with
        | T.Keeper_history_read.History -> T.Kept_request.Keeper_history_read
        | T.Keeper_history_read.Initial_reply -> T.Kept_request.Keeper_reply_read
        | T.Keeper_history_read.Memory -> T.Kept_request.Keeper_memory_read in
      let result =
        try
          let open Result.Syntax in
          let check () = Result.map_error (fun refusal -> T.Request_withdrawn refusal) (check_request ()) in
          let* () = check () in
          let* reading = fetch ~host ~port ~keeper_name
            |> Result.map_error (fun detail -> T.Request_failed detail) in
          let* () = check () |> Result.map_error (Request_notice.request_failure_after_read state ~request) in
          Ok reading
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
            let detail = Printexc.to_string exn in
            Error (T.Request_failed (match source with
              | T.Keeper_history_read.History -> detail
              | T.Keeper_history_read.Initial_reply -> "initial reply: " ^ detail
              | T.Keeper_history_read.Memory -> "memory journal: " ^ detail))
      in
      publish source result
    in
    let read_page () =
      let check_request = Admission.admission_sequence state ~mailbox ~authority ~identity ~host ~port in
      let result =
        try
          let open Result.Syntax in
          let check () = Result.map_error (fun refusal -> T.Request_withdrawn refusal) (check_request ()) in
          let* () = check () in
          let* page = Masc_tui_http.fetch_keeper_chat_history_page ~host ~port ~keeper_name ~cursor:None
            |> Result.map_error (fun error ->
                 T.Request_failed (Keeper_chat_history.page_error_to_string error)) in
          let* () = check ()
            |> Result.map_error (Request_notice.request_failure_after_read state ~request:T.Kept_request.Keeper_history_read) in
          Ok page
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Error (T.Request_failed (Printexc.to_string exn)) in
      T.Keeper_history_read.publish_page request ~ready_at_ns:(Mtime_clock.elapsed_ns ()) result
    in
    let not_run detail =
      publish T.Keeper_history_read.History (Error (T.Request_failed detail));
      publish T.Keeper_history_read.Memory (Error (T.Request_failed detail));
      publish T.Keeper_history_read.Initial_reply (Error (T.Request_failed detail));
      T.Keeper_history_read.publish_page request ~ready_at_ns:(Mtime_clock.elapsed_ns ())
        (Error (T.Request_failed detail)) in
    (match Eio_context.get_switch_opt () with
     | Some sw ->
         (try
            Admission.fork_job ~kind:Masc_tui_workspace_precondition.Observation state ~mailbox ~sw (fun () ->
              Eio.Fiber.all
                ([ (fun () -> read T.Keeper_history_read.History Masc_tui_http.fetch_keeper_chat_history)
                 ; (fun () -> read T.Keeper_history_read.Memory Masc_tui_http.fetch_keeper_memory_journal) ]
                 @ if first_page then
                     [read_page; (fun () -> read T.Keeper_history_read.Initial_reply
                         Masc_tui_http.fetch_keeper_chat_initial_reply)]
                   else []))
          with
          | Eio.Cancel.Cancelled _ as exn -> raise exn
          | exn -> not_run (Printexc.to_string exn))
     | None -> not_run "Eio switch is unavailable");
    (* Full tool detail owns the only lazy read. Compact chat remains byte- and
       network-compatible; repeated history refreshes reuse this separate cache. *)
    if load_file_changes then
      Masc_tui_repo_changes.Workspace_file_changes.launch_keeper_chat_tool_details_load state ~mailbox ~keeper_name
  end
  end
  end

(* Read the open chat's owed history once the pane can take it: the chat is
   on screen at its newest row and no history read is in flight. Runs on
   every loop iteration; it reads only when {!Masc_tui_owed_read.due} says so. *)
let launch_owed_history (state : T.state) ~mailbox =
  match state.T.msg_history_owed with
  | None -> ()
  | Some owed ->
      if owed.T.kho_authority <> state.T.workspace_authority
         || owed.T.kho_reading != state.T.workspace_read_authority
         || state.T.msg_target_keeper_name <> Some owed.T.kho_keeper
      then state.T.msg_history_owed <- None
      else if
        Owed_read.due ~now:(Mono.now ()) owed.T.kho_read
        && state.T.view = T.Keepers T.Keeper_message && state.T.msg_scroll = 0
        && T.server_authority_ready state
        && T.keeper_available_for_new_message state owed.T.kho_keeper
        && Option.is_none state.T.msg_history_inflight
      then
        launch_keeper_history_load ~force:owed.T.kho_audit state
          ~mailbox ~keeper_name:owed.T.kho_keeper

(* Runs on every loop iteration; it reads only a visible Fusion reading whose
   failed read is due. *)
let launch_owed_fusion (state : T.state) ~mailbox =
  Masc_tui_fusion_updates.retry_due_visible state ~now:(Mono.now ())
    ~runs:(fun () -> Masc_tui_ops_requests.Fusion_requests.launch_fusion_runs_load state ~mailbox)
    ~detail:(fun run_id -> Masc_tui_work_actions.Detail_navigation.launch_fusion_detail_load state ~mailbox ~run_id)
    ~historical:(fun reference ->
      Masc_tui_work_actions.Detail_navigation.launch_fusion_historical_detail_load state ~mailbox ~reference)

(* The Keeper detail's composite reading: Info's execution facts and the
   Secrets tab read one Keeper's [/api/v1/keepers/<name>/composite]. It is
   read when a tab opens or [r] asks, when [keeper_composite_changed] names
   the Keeper, and again after a failed read (RFC-0480 §3.1). *)
let current_composite_owed (state : T.state) ~keeper_name =
  match state.T.keeper_composite_owed with
  | Some owed
    when String.equal owed.T.kco_keeper keeper_name
         && owed.T.kco_reading == state.T.detail_read_authority ->
      Some owed
  | Some _ | None -> None

(* A record of another Keeper or detail reading is replaced. *)
let update_composite_owed (state : T.state) ~keeper_name transition =
  let owed =
    match current_composite_owed state ~keeper_name with
    | Some owed -> owed
    | None ->
        { T.kco_keeper = keeper_name
        ; kco_reading = state.T.detail_read_authority
        ; kco_read = Owed_read.settled }
  in
  state.T.keeper_composite_owed <- Some { owed with kco_read = transition owed.T.kco_read }

(* An answer moves only the record it was read for. *)
let settle_composite_owed (state : T.state) ~keeper_name transition =
  match current_composite_owed state ~keeper_name with
  | Some owed ->
      state.T.keeper_composite_owed <- Some { owed with kco_read = transition owed.T.kco_read }
  | None -> ()

let keeper_composite_on_screen (state : T.state) ~keeper_name =
  state.T.view = T.Keepers T.Keeper_detail
  && (match state.T.detail_tab with
      | T.Detail_info | T.Detail_secrets -> true
      | T.Detail_items | T.Detail_sandbox | T.Detail_instructions | T.Detail_github
      | T.Detail_identity | T.Detail_channels | T.Detail_automation | T.Detail_runs
      | T.Detail_terminal -> false)
  && (match T.selected_keeper state with
      | Some keeper -> String.equal keeper.Tui_decode.k_name keeper_name
      | None -> false)

let launch_keeper_composite_load (state : T.state) ~mailbox ~keeper_name =
  if T.server_authority_ready state && Option.is_none state.T.keeper_composite_inflight then begin
    let authority = state.T.detail_read_authority in
    let enqueue_async = Admission.workspace_enqueue state in
    state.T.keeper_composite_inflight <- Some keeper_name;
    settle_composite_owed state ~keeper_name Owed_read.started;
    let host = Admission.server_peer_host in
    let port = state.T.port in
    Admission.launch_async_read state ~mailbox
      ~on_not_run:(fun () ->
        if authority == state.T.detail_read_authority then begin
          state.T.keeper_composite_inflight <- None;
          settle_composite_owed state ~keeper_name Owed_read.abandoned
        end)
      ~deliver:(fun result ->
        enqueue_async mailbox (P.Keeper_msg (P.Keeper_composite_loaded (authority, keeper_name, result))))
      (fun () -> Masc_tui_loader.load_keeper_composite ~host ~port ~keeper_name)
  end

(* Runs on every loop iteration; it reads only the Keeper on screen whose
   read is due. *)
let launch_owed_keeper_composite (state : T.state) ~mailbox =
  match state.T.keeper_composite_owed with
  | None -> ()
  | Some owed ->
      if owed.T.kco_reading != state.T.detail_read_authority
      then state.T.keeper_composite_owed <- None
      else if
        Owed_read.due ~now:(Mono.now ()) owed.T.kco_read
        && keeper_composite_on_screen state ~keeper_name:owed.T.kco_keeper
        && Option.is_none state.T.keeper_composite_inflight
      then launch_keeper_composite_load state ~mailbox ~keeper_name:owed.T.kco_keeper

let owe_keeper_composite_read (state : T.state) ~mailbox ~keeper_name =
  update_composite_owed state ~keeper_name Owed_read.changed;
  launch_owed_keeper_composite state ~mailbox

(* The Keeper_calls surface reads the selected Keeper's tool calls when it
   opens or [r] asks, when [keeper_tool_call] names the Keeper, on a
   revalidation, and again after a failed read (RFC-0480 §3.1). *)
let current_calls_owed (state : T.state) ~keeper_name =
  match state.T.keeper_calls_owed with
  | Some owed
    when String.equal owed.T.kclo_keeper keeper_name
         && owed.T.kclo_reading == state.T.detail_read_authority ->
      Some owed
  | Some _ | None -> None

let update_calls_owed (state : T.state) ~keeper_name transition =
  let owed =
    match current_calls_owed state ~keeper_name with
    | Some owed -> owed
    | None ->
        { T.kclo_keeper = keeper_name
        ; kclo_reading = state.T.detail_read_authority
        ; kclo_read = Owed_read.settled }
  in
  state.T.keeper_calls_owed <- Some { owed with kclo_read = transition owed.T.kclo_read }

let settle_calls_owed (state : T.state) ~keeper_name transition =
  match current_calls_owed state ~keeper_name with
  | Some owed ->
      state.T.keeper_calls_owed <- Some { owed with kclo_read = transition owed.T.kclo_read }
  | None -> ()

(* Runs on every loop iteration. A read the chat pane started for the same
   slot is let finish first, so this record moves only with its own read. *)
let launch_owed_keeper_calls (state : T.state) ~mailbox =
  match state.T.keeper_calls_owed with
  | None -> ()
  | Some owed ->
      if owed.T.kclo_reading != state.T.detail_read_authority
      then state.T.keeper_calls_owed <- None
      else if
        Owed_read.due ~now:(Mono.now ()) owed.T.kclo_read
        && state.T.view = T.Keepers T.Keeper_calls
        && (match T.selected_keeper state with
            | Some keeper -> String.equal keeper.Tui_decode.k_name owed.T.kclo_keeper
            | None -> false)
        && T.server_authority_ready state
        && not state.T.keeper_calls_loading
      then begin
        settle_calls_owed state ~keeper_name:owed.T.kclo_keeper Owed_read.started;
        Masc_tui_work_requests.Schedule_call_requests.launch_keeper_calls_load ~force:true state ~mailbox owed.T.kclo_keeper
      end

let owe_keeper_calls_read (state : T.state) ~mailbox ~keeper_name =
  update_calls_owed state ~keeper_name Owed_read.changed;
  launch_owed_keeper_calls state ~mailbox
