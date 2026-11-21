module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Owed_read = Masc_tui_owed_read
module Mono = Masc_tui_wake.Mono
module Admission = Masc_tui_transport.Workspace_admission
module Collector = Masc_tui_transport.Http_surface_collector
module Owed_read_policy = Masc_tui_owed_surface_reads.Owed_read_policy
module Owed_board_approvals_reads = Masc_tui_owed_surface_reads.Owed_board_approvals_reads
module Owed_runtime_tools_reads = Masc_tui_owed_surface_reads.Owed_runtime_tools_reads
module Keeper_chat_reads = Masc_tui_keeper_journal_reads.Keeper_chat_reads
module Keeper_schedule_memory_reads = Masc_tui_keeper_journal_reads.Keeper_schedule_memory_reads
module Keeper_logs_roster_reads = Masc_tui_keeper_journal_reads.Keeper_logs_roster_reads
module Approvals_asks_settlement = Masc_tui_refresh_settlement.Approvals_asks_settlement
module Refresh_pace = Masc_tui_refresh_pace
module Tui_decode = Masc.Tui_decode

type refresh_hooks = {
  settlement : Server_identity_settlement.hooks;
  observer_browser_scope : T.state -> Masc.Workspace_dataset_event.browser_scope option;
  current_surface_needs : T.state -> T.surface_needs;
}

let launch_owed_ask_followup (state : T.state) ~mailbox =
  match T.ask_followup_target state with
  | None -> state.T.ask_followup_owed <- Owed_read.settled
  | Some _ ->
      if state.T.view = T.Approvals && T.server_authority_ready state
         && Owed_read.due ~now:(Mono.now ()) state.T.ask_followup_owed
      then Masc_tui_operator_actions.Ask_actions.launch_ask_followup_load state ~mailbox

let launch_tick_side_reads (state : T.state) ~mailbox ~(needs : T.surface_needs) =
  if T.server_authority_ready state then begin
  Masc_tui_operator_actions.Ask_actions.launch_ask_followup_load state ~mailbox;
  end

let log_http_surface_read_started (state : T.state) ~full_refresh_running context =
  let request=T.Surface_read_context.current context in
  Log.Transport.info
    "tui_surface_read_started request=%d started_ns=%Ld full_refresh_running=%b navigation_pending=%d context=%s"
    (T.Surface_read_order.request_id request) (T.Surface_read_order.started_ns request)
    full_refresh_running (T.Surface_read_order.navigation_count state.T.http_surface_reads)
    (Yojson.Safe.to_string (T.Surface_read_context.to_yojson context))

(* Observed UI cleanup is not proof of worker exit or received data. Keep
   logging outside finalizers so it cannot replace the original failure there. *)
let log_http_surface_read_finished (state : T.state) context =
  let request=T.Surface_read_context.current context in
  Log.Transport.info
    "tui_surface_read_finished request=%d started_ns=%Ld settled_ns=%Ld navigation_pending=%d context=%s"
    (T.Surface_read_order.request_id request) (T.Surface_read_order.started_ns request)
    (Mtime_clock.elapsed_ns ()) (T.Surface_read_order.navigation_count state.T.http_surface_reads)
    (Yojson.Safe.to_string (T.Surface_read_context.to_yojson context))

let start_http_refresh ~hooks ~server_contact (state : T.state) ~host ~port ~intent ~refresh_inflight
    ~scoped_refresh_inflight ~scoped_refresh_followup ~mailbox =
  (* While [/health] keeps failing, a pass the TUI asks for by itself waits
     for the one the failure owes, which revalidates everything this one
     would, side reads included (RFC tui-one-screen-grammar §2). *)
  let paced =
    Refresh_pace.starts ~now:(Mono.now ()) intent state.T.refresh_pace
  in
  (* The chat pane's history comes down its own generation-guarded path, not
     in the surface bundle. A revalidation owes it a read. Owed, so a pane
     scrolled into older rows or a read in flight takes it when it can; the
     owed read brings the tool details with it. *)
  if paced then begin
    Option.iter
         (fun keeper_name ->
           Keeper_chat_reads.update_history_owed state ~keeper_name Owed_read.changed;
           Keeper_chat_reads.launch_owed_history state ~mailbox)
         state.T.msg_target_keeper_name;
       Option.iter
         (fun (keeper : T.keeper) ->
           Keeper_chat_reads.owe_keeper_composite_read state ~mailbox ~keeper_name:keeper.Tui_decode.k_name;
           Keeper_chat_reads.owe_keeper_calls_read state ~mailbox ~keeper_name:keeper.Tui_decode.k_name)
         (T.selected_keeper state);
       Option.iter
         (fun (keeper : T.keeper) -> Keeper_logs_roster_reads.owe_keeper_logs_read state ~mailbox ~keeper_name:keeper.Tui_decode.k_name)
         (T.keeper_log_target state);
       Option.iter
         (fun post_id -> Owed_board_approvals_reads.owe_board_post_read state ~mailbox ~post_id)
         (Owed_board_approvals_reads.board_post_on_screen state);
       Owed_board_approvals_reads.owe_gate_snapshot_read state;
       Owed_read_policy.owe_held_calls_read state;
       Owed_read_policy.owe_tool_modes_read state;
       Owed_read_policy.owe_keeper_turns_read state;
       Owed_read_policy.owe_verification_read state;
       Owed_read_policy.owe_repositories_read state;
       Owed_read_policy.owe_connectors_read state;
       Owed_read_policy.owe_runtime_config_read state;
       Owed_read_policy.owe_harness_read state;
       T.owe_clients_read state;
       Owed_read_policy.owe_memory_health_read state;
       Owed_read_policy.owe_memory_world_read state;
       if Option.is_some (hooks.observer_browser_scope state) then
         state.T.browser_observation_owed <- Owed_read.changed state.T.browser_observation_owed;
       T.owe_every_identity_login_read state;
       Owed_read_policy.owe_async_requests_read state;
       Owed_runtime_tools_reads.owe_selected_tools_async_detail_read state;
       Owed_runtime_tools_reads.owe_tools_async_task_read state;
       T.owe_tools_reads state;
       Owed_runtime_tools_reads.owe_schedules_read state;
       Keeper_schedule_memory_reads.owe_keeper_schedules_read state;
       Keeper_schedule_memory_reads.owe_keeper_story_turns_read state;
       Keeper_schedule_memory_reads.owe_chat_journal_reads state;
       Owed_read_policy.owe_overview_read state;
       Owed_read_policy.owe_push_owned_revalidation state
  end;
  scoped_refresh_followup :=
    T.note_full_refresh_intent ~intent
      ~full_refresh_inflight:!refresh_inflight
      ~scoped_refresh_inflight:!scoped_refresh_inflight
      !scoped_refresh_followup;
  if not !refresh_inflight && paced then begin
    refresh_inflight := true;
    scoped_refresh_followup := T.No_scoped_followup;
    let refresh_ticket = T.Http_refresh_order.dispatch state.T.http_refresh_order in
    T.begin_http_refresh_state state ~ticket:refresh_ticket
      ~started_ns:(Mtime_clock.elapsed_ns ());
    (* One generation of kept dashboard answers per full pass. A pass reads
       its addresses one after another and can outlive several ticks, and an
       answer read early in it is still kept when the next pass asks. *)
    Masc_tui_http.start_read_generation ();
    let approval_ticket = Approvals_asks_settlement.dispatch_approvals_listing state in
    let ask_request = T.begin_asks_read state in
    (* Read before the label below moves. While the last probe said the
       server is booting, only the probe goes out this tick: the side loads
       below would each wait out a timeout against a process that has not
       finished replaying its stores. An account server serves none of them:
       each would answer 404. The pass also ends at a probe that fails. *)
    let probe_only =
      match state.T.connection_status with
      | T.Booting | T.Account_server _ -> true
      | T.Disconnected | T.Connecting | T.Degraded | T.Connected -> false
    in
    state.T.connection_status <-
      (match state.T.connection_status with
       | T.Connected -> T.Connected
       | T.Degraded -> T.Degraded
       | T.Booting -> T.Booting
       | T.Account_server _ as account_server -> account_server
       | T.Disconnected | T.Connecting -> T.Connecting);
    let needs = hooks.current_surface_needs state in
    let roster_request = if needs.T.needs_keeper_roster
      then T.begin_keeper_roster_read ~intent:T.Snapshot_read.Refresh state
      else None in
    Owed_board_approvals_reads.note_owed_surface_reads_started state needs;
    let reads, surface_request = T.Surface_read_order.dispatch ~kind:T.Surface_read_order.Full ~needs
      ~started_ns:(Mtime_clock.elapsed_ns ()) state.T.http_surface_reads in
    state.T.http_surface_reads <- reads;
    Owed_board_approvals_reads.note_pushed_reads_started state needs;
    let board_query = T.board_query state in
    let surface_context=T.Surface_read_context.capture ~needs ~board_query surface_request in
    let provider_history_days = state.T.provider_history_days in
    let tool_series_days = T.tool_series_days state in
    log_http_surface_read_started state ~full_refresh_running:true surface_context;
    (* The side reads -- the ask follow-up and the identity logins this TUI
       is waiting on -- start after workspace admission, either the cold
       initial-probe acknowledgement or the terminal refresh. The open
       questions the agenda strip counts read on their own announcement
       ([launch_owed_asks]). *)
    if not probe_only then launch_tick_side_reads state ~mailbox ~needs;

    (* This worker owns the binding. The UI's initial-probe acknowledgement is
       the only replacement, before parallel collection starts. Callbacks never
       read a newer workspace authority out of mutable UI state. *)
    let requests = ref
      { P.hrr_authority = state.T.workspace_authority; hrr_approval = approval_ticket;
        hrr_asks = ask_request; hrr_roster = roster_request; hrr_surfaces = surface_context } in
    let cold = state.T.workspace_identity = T.Workspace_identity_unread in
    let early_sources = cold || state.T.workspace_identity = T.Workspace_identity_match in
    let on_initial_identity = if cold then
      Some (fun hir_identity ->
        let acknowledged, hir_acknowledge = Eio.Promise.create () in
        Admission.enqueue mailbox (P.Http_msg (P.Http_initial_identity_read
          { P.hir_ticket = refresh_ticket; hir_authority = (!requests).P.hrr_authority;
            hir_identity; hir_needs = needs; hir_surface_context=(!requests).P.hrr_surfaces; hir_acknowledge }));
        let accepted = Eio.Promise.await acknowledged in
        Option.iter (fun admitted -> requests := admitted) accepted;
        accepted)
      else None in
    let progress_events = state.T.http_refresh_progress_events in
    let on_progress = Some (fun hp_event ->
      T.publish_http_progress progress_events
        { T.hp_ticket = refresh_ticket; hp_authority = (!requests).P.hrr_authority; hp_event };
      Masc_tui_wake.(ring loop Refresh_progress)) in
    let on_dataset = if early_sources then
      Some (fun ed_identity ed_dataset ->
        Admission.enqueue mailbox (P.Http_msg (P.Http_dataset_loaded
          {P.ed_ticket=refresh_ticket;ed_authority=(!requests).P.hrr_authority;
           ed_request=T.Surface_read_context.current (!requests).P.hrr_surfaces;ed_identity;ed_dataset})))
      else None in
    let on_asks =
      if early_sources then
        Some (fun ea_identity ea_observation ->
          Admission.enqueue mailbox (P.Http_msg (P.Http_asks_loaded
            { T.ea_ticket = refresh_ticket; ea_authority = (!requests).P.hrr_authority;
              ea_identity; ea_observation })))
      else None
    in
    let on_approvals =
      if early_sources then
        Some (fun eap_identity eap_observation ->
          Admission.enqueue mailbox (P.Http_msg (P.Http_approvals_loaded
            { P.eap_ticket = refresh_ticket; eap_authority = (!requests).P.hrr_authority;
              eap_identity; eap_observation })))
      else None
    in
    let on_roster =
      if early_sources then
        Some (fun er_identity er_observation ->
          Admission.enqueue mailbox (P.Http_msg (P.Http_keeper_roster_loaded
            {T.er_ticket=refresh_ticket;er_authority=(!requests).P.hrr_authority;er_identity;er_observation})))
      else None in
    (* The slot counts the whole pass. It ends before the answer is queued, so
       the pass that applies the answer already finds it over; the [finally]
       ends it when the worker is cancelled and queues no answer. *)
    let settle_reading = T.reading_begin state in
    let run_refresh () =
      Fun.protect ~finally:(fun () -> settle_reading ~ok:false) (fun () ->
      let failed = ref false in
      let completed = try
          Masc_tui_credential_preparation.await_initial state.T.credential_preparation;
          P.Http_msg (P.Http_refresh_done
             (Collector.load_surfaces ~probe_only ~surface_request ~on_initial_identity ~on_progress ~on_dataset ~on_asks ~on_approvals ~on_roster ~ask_request ~roster_request
                ~refresh_ticket ~host ~port ~approval_ticket
                ~board_query
                ~provider_history_days ~tool_series_days
                ~needs))
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
          failed := true;
          P.Http_msg (P.Http_refresh_failed
            (Printf.sprintf "HTTP refresh failed: %s" (Printexc.to_string exn),
             (!requests).P.hrr_approval, refresh_ticket))
      in
      settle_reading ~ok:(not !failed);
      Admission.enqueue mailbox (P.Http_surface_read_completed ((!requests).P.hrr_surfaces, completed)))
    in
    match Eio_context.get_switch_opt () with
    | Some sw ->
        Eio.Fiber.fork ~sw run_refresh
    | None ->
        Fun.protect
          ~finally:(fun () ->
            settle_reading ~ok:false;
            refresh_inflight := false;
            T.finish_http_surface_read state surface_request;
            Collector.finish_observed_refresh state ~ticket:refresh_ticket)
          (fun () ->
             Masc_tui_credential_preparation.await_initial state.T.credential_preparation;
             Server_identity_settlement.apply_http_refresh_outcome ~hooks:hooks.settlement ~server_contact state ~mailbox
               (Collector.load_surfaces ~probe_only ~surface_request ~on_initial_identity:None ~on_progress:None ~on_dataset:None ~on_asks:None ~on_approvals:None ~on_roster:None ~ask_request ~roster_request
                  ~refresh_ticket ~host ~port ~approval_ticket
                  ~board_query
                ~provider_history_days ~tool_series_days
                ~needs);
             settle_reading ~ok:true);
        log_http_surface_read_finished state surface_context
  end


type read_authority =
  { read_workspace : T.workspace_authority
  ; read_detail : unit ref
  }

let read_authority (state : T.state) =
  { read_workspace = state.T.workspace_authority; read_detail = state.T.detail_read_authority }


let apply_http_scoped_refresh_success ~hooks ~resume_reads_after_authority_change ~server_contact (state : T.state) ~currency_authority ~base_path ~mailbox
    ~refresh_inflight ~scoped_refresh_inflight ~scoped_refresh_followup results =
  if T.Http_refresh_order.is_current state.T.http_refresh_order results.P.http_refresh_ticket then begin
  let was_unavailable =
    state.T.workspace_identity <> T.Workspace_identity_match
    || Option.is_some state.T.keepers_error
  in
  let previous_items = Masc_tui_surface_requests.Keeper_surface_requests.visible_item_revision state in
  let authority = read_authority state in
  let roster_refreshed = Server_identity_settlement.apply_http_scoped_surfaces ~hooks:hooks.settlement state ~mailbox ~currency_authority results in
  if roster_refreshed || Option.is_none results.P.http_keeper_roster then
    Masc_tui_surface_requests.Keeper_surface_requests.refresh_changed_keeper_items state ~mailbox ~roster_refreshed previous_items;
  resume_reads_after_authority_change ~server_contact state ~mailbox ~refresh_inflight
    ~scoped_refresh_inflight ~scoped_refresh_followup ~before:authority;
  Server_identity_settlement.resume_authorized_input_after_refresh state ~was_unavailable ~base_path ~mailbox
  end

let start_http_scoped_refresh ~hooks ~resume_reads_after_authority_change ~server_contact (state : T.state) ~host ~port
    ~(ask : Refresh_pace.screen_ask) ~refresh_inflight
    ~full_refresh_inflight ~scoped_refresh_followup ~mailbox
    ~(needs : T.surface_needs) =
  (* Entering a surface that draws the roster owes it a whole read rather
     than reading it in this bundle. A newer full bundle drops a navigation
     bundle's answers, and with no cadence roster read nothing else would
     free the roster's read slot. *)
  if needs.T.needs_keeper_roster then Keeper_logs_roster_reads.owe_whole_keeper_roster_read state;
  let needs = { needs with needs_keeper_roster = false } in
  let authority = state.T.workspace_authority in
  (* This bundle probes [/health] first, so while the probe keeps failing a
     read the screen owes by itself waits for the pass the failure owes
     (RFC tui-one-screen-grammar §2). A held read starts nothing and records
     no start, so its debt stays owed and its launcher asks again on a later
     loop. Every caller states its [ask]; none is assumed. *)
  if T.surface_needs_any needs
     && Refresh_pace.screen_read_starts ~now:(Mono.now ()) ask
          state.T.refresh_pace
  then begin
    let collection_inflight = !full_refresh_inflight
      || T.Surface_read_order.navigation_in_flight state.T.http_surface_reads in
    refresh_inflight := true;
    let refresh_ticket = T.Http_refresh_order.for_navigation
      ~collection_inflight state.T.http_refresh_order in
    state.T.http_refresh_order <- refresh_ticket;
    Owed_board_approvals_reads.note_owed_surface_reads_started state needs;
    let reads, surface_request = T.Surface_read_order.dispatch ~kind:T.Surface_read_order.Navigation ~needs
      ~started_ns:(Mtime_clock.elapsed_ns ()) state.T.http_surface_reads in
    state.T.http_surface_reads <- reads;
    Owed_board_approvals_reads.note_pushed_reads_started state needs;
    let board_query = T.board_query state in
    let surface_context=T.Surface_read_context.capture ~needs ~board_query surface_request in
    let provider_history_days = state.T.provider_history_days in
    let tool_series_days = T.tool_series_days state in
    log_http_surface_read_started state ~full_refresh_running:!full_refresh_inflight surface_context;
    let approval_ticket =
      if not needs.T.needs_operator_approvals then None
      else Approvals_asks_settlement.dispatch_approvals_listing state
    in
    let ask_request = if needs.T.needs_asks then T.begin_asks_read state else None in
    (* Chat history has its own generation-guarded loader rather than a field
       in the HTTP surface record. It still follows the same delta: entering
       chat asks once; moving among Keeper modes that share the roster does
       not restart it. The read the opening started answers the entry even
       when it landed before this delta ran. *)
    Option.iter (fun keeper_name -> Keeper_chat_reads.launch_keeper_history_load state ~mailbox ~keeper_name)
      (T.chat_entry_read_due state ~needs);
    let currency_authority = {
      P.car_generation = state.T.candle_authority_generation;
      car_identity = state.T.server_identity;
    } in
    let latest_identity = ref None in
    let read_refresh () =
      try
        Masc_tui_credential_preparation.await_initial state.T.credential_preparation;
        let open Result.Syntax in
        let identity = currency_authority.P.car_identity in
        (* A superseded scoped probe must not enqueue an unticketed identity
           withdrawal. Only its ticketed completion may change authority. The
           guard's stop travels as [Request_withdrawn]; an identity read that
           failed stays that read's own failure (RFC §2). *)
        let probe () =
          if authority <> state.T.workspace_authority then Error (T.Request_withdrawn T.Workspace_authority_withdrawn)
          else
            let reading = Masc_tui_loader.load_server_identity ~host ~port in
            latest_identity := Some reading;
            if authority <> state.T.workspace_authority then Error (T.Request_withdrawn T.Workspace_authority_withdrawn)
            else match reading with
              | Error detail -> Error (T.Request_failed detail)
              | Ok identified when T.server_workspace_matches ~expected:identity reading ->
                  Ok identified
              | Ok _ -> Error (T.Request_withdrawn T.Workspace_identity_changed)
        in
        let* server_identity = probe () in
        let on_dataset ed_identity ed_dataset =
          Admission.enqueue mailbox (P.Http_msg (P.Http_dataset_loaded
            {P.ed_ticket=refresh_ticket;ed_authority=authority;ed_request=surface_request;
             ed_identity;ed_dataset})) in
        let readings = Collector.load_scoped_surface_reads ~on_progress:None ~on_dataset:(Some on_dataset) ~surface_request ~ask_request ~refresh_ticket
              ~server_identity:(Ok server_identity) ~host ~port
              ~approval_ticket ~board_query
              ~provider_history_days ~tool_series_days
              ~needs in
        let* confirmed_identity = probe () in
        Ok { readings with http_scoped_server_identity = Ok confirmed_identity }
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> Error (T.Request_failed (Printf.sprintf "HTTP surface refresh failed: %s"
                       (Printexc.to_string exn)))
    in
    let run_refresh () =
      let completed = match read_refresh () with
        | Ok results -> P.Http_msg (P.Http_scoped_refresh_done (authority, currency_authority, results))
        | Error err -> P.Http_msg (P.Http_scoped_refresh_failed
            (authority, err, approval_ticket, refresh_ticket, !latest_identity, surface_request)) in
      Admission.enqueue mailbox (P.Http_surface_read_completed (surface_context, completed))
    in
    match Eio_context.get_switch_opt () with
    | Some sw -> Eio.Fiber.fork ~sw run_refresh
    | None ->
        Fun.protect
          ~finally:(fun () ->
            T.finish_http_surface_read state surface_request;
            refresh_inflight := T.Surface_read_order.navigation_in_flight state.T.http_surface_reads)
          (fun () ->
             match read_refresh () with
             | Ok results when authority = state.T.workspace_authority ->
                 apply_http_scoped_refresh_success ~hooks ~resume_reads_after_authority_change ~server_contact state ~currency_authority
                   ~base_path:state.T.local_base_path ~mailbox
                   ~refresh_inflight:full_refresh_inflight
                   ~scoped_refresh_inflight:refresh_inflight ~scoped_refresh_followup
                   results
             | Error err when authority = state.T.workspace_authority ->
                 let before = read_authority state in
                 Server_identity_settlement.apply_http_scoped_refresh_failure ~hooks:hooks.settlement state ~mailbox
                   ~refresh_ticket ~approval_ticket ~latest:!latest_identity err;
                 resume_reads_after_authority_change ~server_contact state ~mailbox
                   ~refresh_inflight:full_refresh_inflight
                   ~scoped_refresh_inflight:refresh_inflight ~scoped_refresh_followup
                   ~before
             | Ok _ | Error _ -> ());
        log_http_surface_read_finished state surface_context
  end

(* Runs on every loop iteration. A pushed source off screen owes nothing:
   arriving on its surface reads it. A read of it already in flight is let
   finish first. The due sources go out together in one surface bundle. *)
let launch_owed_pushed_reads ~hooks ~resume_reads_after_authority_change ~server_contact (state : T.state) ~refresh_inflight ~full_refresh_inflight
    ~scoped_refresh_followup ~mailbox =
  Owed_read_policy.owe_provider_history_day state ~now:(Unix.gettimeofday ());
  if T.take_tool_series_due state ~now:(Mono.now ()) then
    Owed_read_policy.owe_pushed_read state T.Surface_read_source.Tool_series;
  let wanted = T.Surface_read_order.sources (hooks.current_surface_needs state) in
  let now = Mono.now () in
  let due =
    List.filter
      (fun source ->
        if not (List.mem source wanted) then begin
          Owed_read_policy.set_pushed_read state source Owed_read.settled;
          false
        end
        else begin
          let reading =
            List.exists
              (T.Surface_read_order.pending_dataset state.T.http_surface_reads)
              (T.Surface_read_order.source_datasets source)
          in
          let read =
            if reading then Owed_read_policy.pushed_read state source
            else Owed_read.abandoned (Owed_read_policy.pushed_read state source)
          in
          Owed_read_policy.set_pushed_read state source read;
          Owed_read.due ~now read && not reading
        end)
      T.pushed_sources
  in
  if due <> [] && T.server_authority_ready state then
    start_http_scoped_refresh ~hooks ~resume_reads_after_authority_change ~server_contact state ~host:Admission.server_peer_host ~port:state.T.port
      ~ask:Refresh_pace.Owed_read_due
      ~refresh_inflight ~full_refresh_inflight ~scoped_refresh_followup ~mailbox
      ~needs:
        (List.fold_left
           (fun needs source -> T.with_source needs source true)
           T.nothing due)

(* Runs on every loop iteration. A Board read already in flight is let finish
   first; one that ended unanswered waits and reads again
   ([unanswered_read]). The scoped and full refreshes record the start of
   every Board read ([note_owed_surface_reads_started]). Only a matched
   workspace applies the list, so only a matched workspace reads it. *)
let launch_owed_board_list ~hooks ~resume_reads_after_authority_change ~server_contact (state : T.state) ~refresh_inflight ~full_refresh_inflight
    ~scoped_refresh_followup ~mailbox =
  if state.T.view <> T.Board then state.T.board_list_owed <- Owed_read.settled
  else begin
    let reading =
      T.Surface_read_order.pending_dataset state.T.http_surface_reads T.Surface_read_order.Board_posts
    in
    let read =
      if reading then state.T.board_list_owed
      else Owed_board_approvals_reads.unanswered_read state.T.board_list_owed
    in
    state.T.board_list_owed <- read;
    if Owed_read.due ~now:(Mono.now ()) read
       && T.server_authority_ready state
       && state.T.workspace_identity = T.Workspace_identity_match
       && not reading
    then
      start_http_scoped_refresh ~hooks ~resume_reads_after_authority_change ~server_contact state ~host:Admission.server_peer_host ~port:state.T.port
        ~ask:Refresh_pace.Owed_read_due
        ~refresh_inflight ~full_refresh_inflight ~scoped_refresh_followup ~mailbox
        ~needs:{ T.nothing with needs_board = true }
  end

(* Runs on every loop iteration. A dataset already in flight is let finish
   first; one that ended unanswered waits and reads again
   ([unanswered_read]). Only the datasets whose debt is due are read; the
   scoped refresh records their start ([note_owed_surface_reads_started]).
   Only a matched workspace applies them, so only a matched workspace reads
   them. *)
let launch_owed_planning ~hooks ~resume_reads_after_authority_change ~server_contact (state : T.state) ~refresh_inflight ~full_refresh_inflight
    ~scoped_refresh_followup ~mailbox =
  if state.T.view <> T.Planning then begin
    state.T.planning_owed <- Owed_read.settled;
    state.T.overview_goals_owed <- Owed_read.settled
  end else begin
    let pending dataset =
      T.Surface_read_order.pending_dataset state.T.http_surface_reads dataset
    in
    let planning_reading = pending T.Surface_read_order.Planning_data in
    let goals_reading = pending T.Surface_read_order.Overview_goals_data in
    let planning =
      if planning_reading then state.T.planning_owed
      else Owed_board_approvals_reads.unanswered_read state.T.planning_owed
    in
    let goals =
      if goals_reading then state.T.overview_goals_owed
      else Owed_board_approvals_reads.unanswered_read state.T.overview_goals_owed
    in
    state.T.planning_owed <- planning;
    state.T.overview_goals_owed <- goals;
    let now = Mono.now () in
    let planning_due = Owed_read.due ~now planning && not planning_reading in
    let goals_due = Owed_read.due ~now goals && not goals_reading in
    if (planning_due || goals_due) && T.server_authority_ready state
       && state.T.workspace_identity = T.Workspace_identity_match then
      start_http_scoped_refresh ~hooks ~resume_reads_after_authority_change ~server_contact state ~host:Admission.server_peer_host ~port:state.T.port
        ~ask:Refresh_pace.Owed_read_due
        ~refresh_inflight ~full_refresh_inflight ~scoped_refresh_followup ~mailbox
        ~needs:{ T.nothing with
                 needs_planning = planning_due; needs_overview_goals = goals_due }
  end

let start_scoped_refresh_followup ~hooks ~server_contact (state : T.state) ~host ~port ~refresh_inflight
    ~scoped_refresh_inflight ~scoped_refresh_followup ~mailbox =
  let next, launch =
    T.take_scoped_refresh_followup
      ~full_refresh_inflight:!refresh_inflight
      ~scoped_refresh_inflight:!scoped_refresh_inflight
      !scoped_refresh_followup
  in
  scoped_refresh_followup := next;
  if launch then
    start_http_refresh ~hooks ~server_contact state ~host ~port ~intent:T.Revalidate ~refresh_inflight
      ~scoped_refresh_inflight ~scoped_refresh_followup ~mailbox

(* Runs on every loop iteration. A failing [/health] probe owes one pass,
   which starts once its wait is over, whether or not anything asked
   (RFC tui-one-screen-grammar §2). Only a full pass in flight holds it: a
   screen read in flight is the same case for this pass as for any other,
   and [start_http_refresh] decides it through [note_full_refresh_intent]. *)
let launch_owed_refresh_pass ~hooks ~server_contact (state : T.state) ~refresh_inflight ~scoped_refresh_inflight
    ~scoped_refresh_followup ~mailbox =
  if not !refresh_inflight
     && Refresh_pace.due ~now:(Mono.now ()) state.T.refresh_pace
  then
    start_http_refresh ~hooks ~server_contact state ~host:Admission.server_peer_host ~port:state.T.port ~intent:T.Owed_pass
      ~refresh_inflight ~scoped_refresh_inflight ~scoped_refresh_followup ~mailbox
