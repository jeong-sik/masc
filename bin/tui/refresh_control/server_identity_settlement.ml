module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Fetched = Masc_tui_fetched
module Admission = Masc_tui_transport.Workspace_admission
module Server_contact = Masc_tui_transport.Server_contact
module Local_sources = Masc_tui_transport.Local_sources
module Workspace_settlement = Masc_tui_refresh_settlement.Workspace_settlement
module Approvals_asks_settlement = Masc_tui_refresh_settlement.Approvals_asks_settlement
module Http_dataset_settlement = Masc_tui_refresh_settlement.Http_dataset_settlement
module Board_detail = Masc_tui_board_detail
module Goal_confirmation = Masc_tui_planning_detail
module Keeper_chat = Masc_tui_keeper_chat_projection
module Chat_queue = Masc_tui_keeper_chat_queue
module Keeper_control = Masc_tui_keeper_control
module Refresh_pace = Masc_tui_refresh_pace
module Tui_decode = Masc.Tui_decode

type hooks = {
  withdraw_diagram : T.state -> unit;
  retire_remote_image : T.state -> unit;
  settle_retired_sent_image : T.state -> unit;
  withdraw_keeper_presentation :
    T.state ->
    previous:T.workspace_input_identity option ->
    keep_detail_navigation:bool ->
    draft:Masc_tui_message_input.snapshot ->
    unit;
}

let apply_confirmed_server_identity_reading ~hooks (state : T.state) ~mailbox reading =
  let previous_server = state.T.server_identity in
  let previous_input_workspace = T.workspace_input_identity_of_server previous_server in
  (* A withdrawal invalidates outstanding roster reads even if the same
     workspace becomes ready again before those reads finish. *)
  if not (Workspace_settlement.same_currency_workspace state.T.server_identity (Result.to_option reading))
  then Workspace_settlement.withdraw_currency_authority state;
  let same_item_authority =
    match state.T.server_identity, reading with
    | Some previous, Ok current ->
        previous.Tui_decode.sid_state_ready <> Some false
        && current.Tui_decode.sid_state_ready <> Some false
        && Admission.same_server_workspace previous current
    | None, _ | Some _, Error _ -> false
  in
  if not same_item_authority then begin
    T.remember_keeper_detail_focus state;
    Masc_tui_surface_requests.Keeper_surface_requests.withdraw_keeper_items state;
    Workspace_settlement.revoke_detail_readings state
  end;
  T.reconcile_detail_intent_origins state reading;
  let previous = state.T.workspace_identity in
  let chat_workspace = T.chat_input_workspace state in
  T.store_server_identity_reading state reading;
  state.T.workspace_identity <-
    T.workspace_identity_of_refresh
      ~local_paths:state.T.local_workspace_paths reading;
  if state.T.workspace_identity <> T.Workspace_identity_match then begin
    state.T.goal_action_pending <- None;
    (* Withdraw decision authority even when this refresh did not ask for
       Home. A later matching Metrics read cannot revive foreign/stale tokens. *)
    let reason = "workspace identity is unverified; decisions require a fresh matching read" in
    Approvals_asks_settlement.apply_approvals_load state (Error (T.Request_failed reason));
    state.T.board_listing <- Fetched.Failed reason;
    state.T.board_list_reported_error <- None;
    state.T.approval_list_scroll <- 0;
    state.T.board_census <- Fetched.Absent;
    state.T.board_detail <- Board_detail.clear state.T.board_detail;
    state.T.board_vote_armed <- None;
    state.T.keeper_roster <- Keeper_control.unobserved_roster;
    state.T.keeper_roster_error <- Some reason;
    state.T.msg_history_load_generation <- state.T.msg_history_load_generation + 1;
    state.T.msg_history_inflight <- None;
    state.T.keeper_tool_approvals <- [];
    state.T.keeper_tool_approvals_observed <- false;
    state.T.keeper_tool_approvals_error <- Some reason;
    state.T.keeper_tool_approvals_read <- T.Snapshot_read.invalidate state.T.keeper_tool_approvals_read;
    state.T.gate_pending <- [];
    state.T.gate_modes <- None;
    state.T.gate_rules <- [];
    state.T.gate_queue_unavailable <- Some reason;
    state.T.gate_rules_unavailable <- Some reason;
    state.T.gate_error <- Some reason;
    state.T.gate_snapshot_observed <- false;
    state.T.gate_snapshot_authority <- None;
    state.T.gate_snapshot_read <- T.Snapshot_read.invalidate state.T.gate_snapshot_read;
    state.T.asks_snapshot <- None;
    Masc_tui_frame_timing.note_asks_application Masc_tui_frame_timing.Reset;
    T.retire_asks_read state;
    Approvals_asks_settlement.apply_asks_load state (Error reason);
    Http_dataset_settlement.apply_planning_load state (Error reason);
    Http_dataset_settlement.apply_overview_goals_load state (Error reason);
    state.T.goals_to_confirm <- Masc_tui_agenda.Not_read;
    (match state.T.goal_confirmation with
     | Goal_confirmation.Inspecting read ->
         state.T.goal_confirmation <- Goal_confirmation.Inspecting
           (Fetched.clear read)
     | Goal_confirmation.Submitting _ -> ())
  end;
  let same_workspace =
    T.server_workspace_matches ~expected:previous_server reading
    && match previous, state.T.workspace_identity with
    | (T.Workspace_identity_match | T.Workspace_identity_match_unconfirmed _)
    , T.Workspace_identity_match -> true
    | T.Workspace_identity_mismatch prior, T.Workspace_identity_mismatch current ->
      String.equal prior.server_base_path current.server_base_path
    | (T.Workspace_identity_match | T.Workspace_identity_match_unconfirmed _)
    , (T.Workspace_identity_unread | T.Workspace_identity_match_unconfirmed _
      | T.Workspace_identity_mismatch _)
    | T.Workspace_identity_mismatch _
    , (T.Workspace_identity_unread | T.Workspace_identity_match
      | T.Workspace_identity_match_unconfirmed _)
    | T.Workspace_identity_unread
    , (T.Workspace_identity_unread | T.Workspace_identity_match
      | T.Workspace_identity_match_unconfirmed _ | T.Workspace_identity_mismatch _) -> false
  in
  if not same_workspace then begin
    (* Recover local input before cancellation drops its preflight owner.
       Streaming/reconciling owners may have reached the server. *)
    T.retain_preflight_inputs state state.T.msg_inflight;
    Masc_tui_surface_requests.Keeper_surface_requests.withdraw_keeper_items state;
    let T.Workspace_authority generation = state.T.workspace_authority in
    state.T.workspace_authority <- T.Workspace_authority (generation + 1);
    let cancellations = state.T.workspace_cancellations in
    state.T.workspace_cancellations <- [];
    List.iter (fun (_, cancel) -> cancel ()) cancellations;
    state.T.keeper_action_pending <- None;
    (* A failed local reload may retain only rows from that same authority. *)
    state.T.keepers <- [];
    state.T.keepers_error <- None;
    (* An identity that only went unread is not another workspace: the open
       chat, its draft, queue and focus stay, so the operator's typing keeps
       going to the composer instead of the Keeper list's keys (x deletes).
       It comes back to the same workspace's Match, or is put away with the
       rest when the identity reads as another workspace. *)
    let preserve_chat =
      state.T.view = T.Keepers T.Keeper_message
      && Option.is_some state.T.msg_target_keeper_name
      && match chat_workspace, state.T.workspace_identity with
         | Some _, (T.Workspace_identity_unread | T.Workspace_identity_match_unconfirmed _) -> true
         | Some origin, T.Workspace_identity_match ->
             Some origin = T.workspace_input_identity_of_server state.T.server_identity
         | None, _ | Some _, T.Workspace_identity_mismatch _ -> false
    in
    let target = state.T.msg_target_keeper_name in
    let draft = Masc_tui_message_input.snapshot state.T.msg_input in
    let spill = T.message_spill_in_snapshot state draft in
    let attachments = state.T.msg_attachments and references = state.T.msg_references in
    let since = state.T.msg_attachments_since and queue = state.T.msg_queued in
    let recall_walk = state.T.msg_recall_walk in
    let focused = state.T.composer_focused in
    let retained = T.retained_input_markers queue state.T.keeper_interactive_waiting in
    let withdrawn_workspace = match state.T.msg_unconfirmed_workspace with
      | Some _ -> chat_workspace
      | None -> previous_input_workspace
    in
    let keep_detail_navigation =
      match previous, state.T.workspace_identity with
      | T.Workspace_identity_unread, _ | _, T.Workspace_identity_unread -> true
      | ( T.Workspace_identity_match | T.Workspace_identity_match_unconfirmed _
        | T.Workspace_identity_mismatch _ )
      , ( T.Workspace_identity_match | T.Workspace_identity_match_unconfirmed _
        | T.Workspace_identity_mismatch _ ) -> false
    in
    (* Keep a name through initial confirmation or a temporary loss of its
       original workspace, but never carry an A-owned name into B. An
       unbound name still requires an explicit workspace confirmation. *)
    let current_preset_workspace = T.workspace_input_identity_of_server state.T.server_identity in
    let preserved_preset_draft =
      match state.T.preset_save_draft, state.T.preset_save_draft_workspace,
            current_preset_workspace with
      | None, _, _ -> None
      | Some draft, Some origin, Some current when origin <> current ->
        let held = { T.psd_name = draft; psd_description = state.T.preset_save_draft_description
                   ; psd_source = state.T.preset_save_draft_source } in
        state.T.preset_save_suspended_drafts <- (origin, held) :: state.T.preset_save_suspended_drafts;
        None
      | Some draft, origin, _ ->
        Some ({ T.psd_name = draft; psd_description = state.T.preset_save_draft_description
              ; psd_source = state.T.preset_save_draft_source }, origin)
    in
    hooks.withdraw_keeper_presentation state ~previous:withdrawn_workspace
      ~keep_detail_navigation ~draft;
    let restore_preset_draft = match preserved_preset_draft, current_preset_workspace with
      | Some _ as kept, _ -> kept
      | None, None -> None
      | None, Some workspace ->
        (match List.assoc_opt workspace state.T.preset_save_suspended_drafts with
         | None -> None
         | Some draft ->
           state.T.preset_save_suspended_drafts <-
             List.remove_assoc workspace state.T.preset_save_suspended_drafts;
           Some (draft, Some workspace)) in
    Option.iter (fun (draft, origin) ->
      state.T.preset_save_draft <- Some draft.T.psd_name;
      state.T.preset_save_draft_description <- draft.T.psd_description;
      state.T.preset_save_draft_source <- draft.T.psd_source;
      state.T.preset_save_draft_workspace <- origin) restore_preset_draft;
    if preserve_chat then begin
      T.retarget_message state target;
      state.T.view <- T.Keepers T.Keeper_message;
      state.T.composer_focused <- focused;
      Masc_tui_message_input.clear state.T.msg_input;
      Masc_tui_message_input.insert state.T.msg_input
        (T.expand_message_draft_spill spill (Masc_tui_message_input.snapshot_text draft));
      (Masc_tui_message_input.invalidate_revision state.T.msg_input; state.T.msg_attachments <- attachments);
      (Masc_tui_message_input.invalidate_revision state.T.msg_input; state.T.msg_references <- references);
      state.T.msg_attachments_since <- since;
      state.T.msg_recall_walk <- recall_walk;
      state.T.msg_queued <- queue;
      state.T.keeper_interactive_waiting <- retained;
      List.iter (fun (item : Chat_queue.item) ->
        Masc_tui_chat_dispatch.Chat_watching.append_user_history_once ~submitted_at:item.Chat_queue.submitted_at state item.Chat_queue.request)
        (Chat_queue.waiting queue);
      (* The presentation withdrawal suspended this chat's input for its
         workspace; it is back on screen, so it is not suspended twice. *)
      state.T.suspended_keeper_inputs <- List.remove_assoc withdrawn_workspace
        state.T.suspended_keeper_inputs;
      state.T.msg_unconfirmed_workspace <-
        (match state.T.workspace_identity with
         | T.Workspace_identity_unread | T.Workspace_identity_match_unconfirmed _ -> chat_workspace
         | T.Workspace_identity_match | T.Workspace_identity_mismatch _ -> None)
    end else state.T.msg_unconfirmed_workspace <- None
  end;
  match state.T.workspace_identity with
  | T.Workspace_identity_mismatch _ ->
    let same_remote = same_workspace in
    Masc_tui_loader.clear_local_workspace ~keep_keeper_rows:same_remote state;
    T.clear_keeper_logs state;
    if not same_remote then begin
      state.T.keeper_roster <- Keeper_control.unobserved_roster;
      state.T.keeper_roster_error <- None
    end
  | T.Workspace_identity_match ->
    (* The same workspace read as a match again leaves the keeper rows and
       tasks as the cadence tick last loaded them, a refresh ago. A reload
       here ran the whole directory read on the UI thread a second time for
       the same answer. A workspace that just changed, or one that was not
       a match a moment ago, has had its rows put away above and needs it. *)
    (match previous with
     | T.Workspace_identity_match when same_workspace -> ()
     | T.Workspace_identity_match
     | T.Workspace_identity_unread
     | T.Workspace_identity_match_unconfirmed _
     | T.Workspace_identity_mismatch _ ->
         state.T.local_workspace <- T.Local_workspace_unread;
         state.T.local_keepers <- T.Local_workspace_unread;
         Local_sources.launch_workspace_read state ~mailbox ~intent:T.Snapshot_read.Join state.T.local_base_path);
    let input_workspace = T.workspace_input_identity_of_server state.T.server_identity in
    (match List.assoc_opt input_workspace state.T.suspended_keeper_inputs with
     | None -> ()
     | Some held ->
       state.T.suspended_keeper_inputs <- List.remove_assoc input_workspace
         state.T.suspended_keeper_inputs;
       T.restore_suspended_keeper_input state held;
       List.iter (fun (item : Chat_queue.item) ->
         Masc_tui_chat_dispatch.Chat_watching.append_user_history_once ~submitted_at:item.Chat_queue.submitted_at state item.Chat_queue.request)
         (Chat_queue.waiting state.T.msg_queued);
       Masc_tui_loader.report_action state "system"
         "Retained inputs restored for this workspace; resume a Keeper to send them")
  | T.Workspace_identity_unread ->
    state.T.item_account_error <- Some "Server workspace identity is unavailable";
    Masc_tui_loader.clear_local_workspace state;
    state.T.keeper_roster <- Keeper_control.unobserved_roster;
    T.clear_keeper_logs state
  | T.Workspace_identity_match_unconfirmed _ ->
    (* [workspace_identity_of_refresh] answers only the three confirmed
       readings; [apply_server_identity_reading] keeps an unconfirmed match
       before this function runs. *)
    ()

(* The selected Goal id belongs to the Planning detail, regardless of whether
   the latest Goal snapshot has arrived. *)
let selected_planning_goal_id (state : T.state) =
  match state.T.view with
  | T.Planning ->
      (match state.T.planning_mode with
       | T.Planning_list -> None
       | T.Planning_detail goal_id -> Some goal_id)
  | T.Overview | T.Acting | T.Metrics | T.Keepers _ | T.Memory | T.Lanes | T.Clients | T.Board
  | T.Approvals | T.Schedules | T.Verification | T.Harness | T.Fusion | T.Repositories
  | T.Code | T.Changes | T.Connectors | T.Runtime | T.Config | T.Resources | T.Tools
  | T.System_logs -> None

(* A read that cannot say which workspace the server serves keeps the last
   match unconfirmed ([Masc_tui_types.next_workspace_identity]). The confirmed
   identity and everything it authorized stay; the state is no longer
   [Workspace_identity_match], so decisions and new reads wait for a read that
   matches again. Only a read that names a workspace goes on to compare it. *)
let apply_server_identity_reading ?(withdraw_on_error = false) ~hooks (state : T.state) ~mailbox reading =
  hooks.withdraw_diagram state;
  let previous_identity = state.T.server_identity in
  let previous_instance = Option.bind state.T.server_identity (fun identity -> identity.Tui_decode.sid_runtime_instance_id) in
  (match
    (match reading with
     | Error _ when withdraw_on_error -> T.Workspace_identity_unread
     | Ok _ | Error _ ->
         T.next_workspace_identity ~previous:state.T.workspace_identity
           ~local_paths:state.T.local_workspace_paths reading)
  with
  | T.Workspace_identity_match_unconfirmed _ as unconfirmed ->
    state.T.workspace_identity <- unconfirmed;
    T.suspend_workspace_readings state;
    hooks.settle_retired_sent_image state;
    Masc_tui_chat_dispatch.Chat_journals.settle_retired_chat_copy state;
    Masc_tui_collab_queue.Keeper_queue.settle_retired_queue_inspections state;
    Masc_tui_surface_requests.Prompt_preset_requests.settle_retired_chat_command_reads state
  | T.Workspace_identity_unread | T.Workspace_identity_match
  | T.Workspace_identity_mismatch _ as next ->
    (match state.T.workspace_identity, next with
     | T.Workspace_identity_match_unconfirmed _, T.Workspace_identity_match ->
       (* A detail read answered while the identity was unconfirmed was
          dropped. Retiring the receipts still in flight makes the move back
          visible to [resume_reads_after_authority_change], which reads the
          open detail again; the screen keeps what it shows meanwhile. *)
       state.T.detail_reads <- [];
       state.T.detail_read_authority <- ref ()
     | ( T.Workspace_identity_unread | T.Workspace_identity_match
       | T.Workspace_identity_match_unconfirmed _ | T.Workspace_identity_mismatch _ ), _ -> ());
    apply_confirmed_server_identity_reading ~hooks state ~mailbox reading);
  let current_instance = Option.bind state.T.server_identity (fun identity -> identity.Tui_decode.sid_runtime_instance_id) in
  if previous_instance <> current_instance then begin
    state.T.goal_candle <- Fetched.clear state.T.goal_candle;
    state.T.goal_confirmation_presented <- None;
    let confirmation_key = (match state.T.goal_confirmation with
     | Goal_confirmation.Inspecting read ->
       state.T.goal_confirmation <- Goal_confirmation.Inspecting (Goal_confirmation.suspend_confirmation_read read);
       Fetched.current_key read
     | Goal_confirmation.Submitting _ -> None) in
    state.T.goal_confirmation_identity_refresh <-
      (match confirmation_key, previous_identity with
       | Some goal_id, Some identity ->
           Some (goal_id, Goal_confirmation.confirmation_workspace_of_identity identity)
       | (None, _ | _, None) -> None);
    match selected_planning_goal_id state with
    | Some goal_id when T.server_authority_ready state ->
      Masc_tui_work_requests.Tools_task_requests.launch_goal_candle_load state ~mailbox goal_id
    | Some _ | None -> ()
  end

let apply_refused_workspace_identity ~hooks (state : T.state) ~mailbox ~detail latest =
  hooks.withdraw_diagram state;
  let reading = T.retire_refused_workspace_readings state ~detail latest in
  apply_server_identity_reading ~hooks state ~mailbox reading

(* Scoped navigation reads carry the final identity of their verified interval.
   A successful older full refresh cannot authorize a same-port replacement. *)
let apply_http_scoped_surfaces ~hooks (state : T.state) ~mailbox ~currency_authority results =
  if T.Http_refresh_order.is_current state.T.http_refresh_order results.P.http_refresh_ticket then begin
    let admission = T.collector_admission state results.P.http_surface_request
      results.P.http_scoped_server_identity in
    let datasets = T.take_http_surface_datasets state results.P.http_surface_request in
    (* Older collectors can still own independent data. Their older probe
       cannot replace identity observed by a newer collector. *)
    (match admission with
     | T.Admit_identity_and_data | T.Admit_identity_only ->
         Http_dataset_settlement.note_server_health state ~answered:Refresh_pace.answered_again
           results.P.http_scoped_server_identity;
         apply_server_identity_reading ~hooks state ~mailbox results.P.http_scoped_server_identity
     | T.Admit_data_only | T.Admit_nothing -> ());
    match admission with
    | T.Admit_identity_and_data | T.Admit_data_only ->
      (* Identity application can withdraw authority even when this response
         has the current ticket. Only the dispatch generation and workspace
         together authorize its roster; other datasets retain their ticket. *)
      let same_workspace =
        currency_authority.P.car_generation = state.T.candle_authority_generation
        && Workspace_settlement.same_currency_workspace currency_authority.P.car_identity state.T.server_identity
      in
      let results = if same_workspace then results
        else { results with http_keeper_roster = None } in
      Http_dataset_settlement.apply_http_scoped_data ~before_view_change:(fun () -> hooks.retire_remote_image state) state ~datasets results
    | T.Admit_identity_only | T.Admit_nothing -> false
  end else false

let resume_authorized_input_after_refresh (state : T.state) ~was_unavailable ~base_path ~mailbox =
  if was_unavailable
     && state.T.workspace_identity = T.Workspace_identity_match
     && Option.is_none state.T.keepers_error then begin
    Chat_queue.waiting state.T.msg_queued
    |> List.map (fun (item : Chat_queue.item) -> item.Chat_queue.request.Keeper_chat.keeper_name)
    |> List.sort_uniq String.compare
    |> List.iter (fun keeper_name ->
         Masc_tui_chat_dispatch.Queue_steer.launch_waiting_keeper_input state ~mailbox ~keeper_name);
    state.T.keeper_run_next_ready
    |> List.map (fun (request : Keeper_chat.request) -> request.Keeper_chat.keeper_name)
    |> List.sort_uniq String.compare
    |> List.iter (Masc_tui_chat_dispatch.Queue_steer.dispatch_ready_run_next state ~mailbox);
    Option.iter (fun panel -> Masc_tui_collab_queue.Keeper_queue.refresh_queue_after_priority state ~mailbox ~keeper_name:panel.T.qp_keeper)
      state.T.queue_panel;
    Masc_tui_chat_dispatch.Queue_steer.drain_queued_message state ~base_path ~mailbox
  end

(* A scoped refresh the guard stopped settles as a failed one does; only its
   words differ: the kept-back notice alone, never the read's failure
   (RFC §2). *)
let apply_http_scoped_refresh_failure ~hooks (state : T.state) ~mailbox ~refresh_ticket ~approval_ticket ~latest failure =
  if T.Http_refresh_order.is_current state.T.http_refresh_order refresh_ticket then begin
    let err = T.request_failure_text ~ko:(state.T.ui_language = T.Lang_ko)
        ~request:T.Kept_request.Surface_read failure in
    (* The last [/health] reading its probes took, the probe's own answer
       whatever stopped the refresh after it. *)
    Option.iter
      (Http_dataset_settlement.note_server_health state ~answered:Refresh_pace.answered_again) latest;
    apply_refused_workspace_identity ~hooks state ~mailbox ~detail:err latest;
    Option.iter
      (fun ao_ticket ->
         if Approvals_asks_settlement.admit_approval_listing state ao_ticket then
           Approvals_asks_settlement.apply_approvals_read state (Error failure))
      approval_ticket;
    Masc_tui_loader.add_event state "error" err
  end

(* A refresh pass settled, and its [/health] probe read [identity]. *)
let note_refresh_settled (state : T.state) identity =
  Http_dataset_settlement.note_read state Masc_tui_read_failure.Refresh_pass (Ok ());
  Http_dataset_settlement.note_server_health state ~answered:Refresh_pace.pass_answered identity

let apply_http_surfaces ~hooks (state : T.state) ~mailbox results =
  if T.Http_refresh_order.is_current state.T.http_refresh_order
       results.P.http_scoped.P.http_refresh_ticket then begin
  note_refresh_settled state results.P.http_server_identity;
  let previous_items = Masc_tui_surface_requests.Keeper_surface_requests.visible_item_revision state in
  let request = results.P.http_scoped.P.http_surface_request in
  (* Navigation joins this pass's ticket while it runs, so the ticket alone
     cannot tell whether a newer collector already read the identity. *)
  let admission = T.collector_admission state request results.P.http_server_identity in
  let datasets = T.take_http_surface_datasets state request in
  (match admission with
   | T.Admit_identity_and_data | T.Admit_identity_only ->
       apply_server_identity_reading ~hooks state ~mailbox results.P.http_server_identity
   | T.Admit_data_only | T.Admit_nothing -> ());
  let roster_refreshed = match admission with
    | T.Admit_identity_and_data | T.Admit_data_only ->
        if state.T.workspace_identity = T.Workspace_identity_match then
          Option.iter (Approvals_asks_settlement.apply_approval_answer_observation state) results.P.http_approvals;
        Http_dataset_settlement.apply_http_scoped_data ~before_view_change:(fun () -> hooks.retire_remote_image state) state ~datasets results.P.http_scoped
    | T.Admit_identity_only | T.Admit_nothing -> false in
  if roster_refreshed || Option.is_none results.P.http_scoped.P.http_keeper_roster then
    Masc_tui_surface_requests.Keeper_surface_requests.refresh_changed_keeper_items state ~mailbox ~roster_refreshed previous_items;
  let reached result =
    Result.map (fun _ -> ()) result |> Result.map_error (fun _ -> ())
  in
  let reached_if_asked result = Option.map reached result |> Option.to_list in
  (* Identity is server contact too: failed surface reads must not report
     the process offline when the workspace probe just answered. Only the
     surfaces actually requested contribute their outcomes. *)
  state.T.connection_status <-
    T.connection_status_of_refresh
      ~identity:(reached results.P.http_server_identity)
      ~surfaces:(reached_if_asked (Option.map (fun receipt -> receipt.T.bpr_result) results.P.http_scoped.P.http_board)
       @ reached_if_asked results.P.http_scoped.P.http_planning
       @ (Option.map
            (fun observation -> reached observation.P.ao_result)
            results.P.http_approvals
          |> Option.to_list))
  end

let apply_server_booting ~hooks (state : T.state) ~mailbox ~refresh_ticket ~identity ~approval_ticket =
  if T.Http_refresh_order.is_current state.T.http_refresh_order refresh_ticket then begin
  note_refresh_settled state identity;
  (* The identity is read the same way a full refresh reads it, so a same-port
     replacement is noticed even while the new process is still booting. No
     surface was asked. The approvals panel is told why its rows are stale,
     as a failed refresh tells it; nothing else changes. *)
  apply_server_identity_reading ~hooks state ~mailbox identity;
  Http_dataset_settlement.apply_keeper_roster_load ~before_view_change:(fun () -> hooks.retire_remote_image state) state
    (Error (Keeper_control.Roster_unreachable "server booting"));
  Option.iter
    (fun ao_ticket ->
       Approvals_asks_settlement.apply_approval_observation state
         { P.ao_ticket; ao_result = Error "server booting" })
    approval_ticket;
  state.T.connection_status <- T.Booting
  end

(* The account server of a multi-account installation serves no workspace,
   and nothing but the probe was asked. The readings in flight are retired as
   for a refused workspace, so a read cut off here says so; then the identity
   is withdrawn, since there is no workspace to wait for. The approvals
   panel, the roster and Candle are told why. *)
let account_server_reason =
  "the address answers as the account server of a multi-account installation, which serves no workspace"

let apply_account_server ~hooks ~server_contact (state : T.state) ~mailbox ~refresh_ticket ~version ~approval_ticket =
  if T.Http_refresh_order.is_current state.T.http_refresh_order refresh_ticket then begin
  (* The probe answered; what answered is the account server. *)
  note_refresh_settled state (Ok ());
  (* The footer's last notice was said on the screen this one covers, such
     as the settings this server could not answer at start. *)
  (match state.T.connection_status with
   | T.Account_server _ -> ()
   | T.Disconnected | T.Connecting | T.Booting | T.Degraded | T.Connected -> T.set_last_action state None);
  apply_refused_workspace_identity ~hooks state ~mailbox ~detail:account_server_reason None;
  apply_server_identity_reading ~hooks ~withdraw_on_error:true state ~mailbox (Error account_server_reason);
  Server_contact.spend_auto_start server_contact;
  state.T.candle_observation <- Some (Error account_server_reason);
  Http_dataset_settlement.apply_keeper_roster_load ~before_view_change:(fun () -> hooks.retire_remote_image state) state
    (Error (Keeper_control.Roster_unreachable account_server_reason));
  Option.iter
    (fun ao_ticket ->
       Approvals_asks_settlement.apply_approval_observation state
         { P.ao_ticket; ao_result = Error account_server_reason })
    approval_ticket;
  state.T.connection_status <- T.Account_server { version }
  end

let apply_workspace_unconfirmed ~hooks (state : T.state) ~mailbox ~detail ~unreachable ~approval_ticket ~latest_identity =
  note_refresh_settled state latest_identity;
  apply_refused_workspace_identity ~hooks state ~mailbox ~detail (Some latest_identity);
  (* The Candle surface says why it has no reading rather than looking
     unread. *)
  state.T.candle_observation <- Some (Error detail);
  Option.iter (fun ao_ticket ->
    Approvals_asks_settlement.apply_approval_observation state {P.ao_ticket; ao_result = Error detail}) approval_ticket;
  state.T.connection_status <-
    (if unreachable then T.Disconnected else T.Degraded);
  Masc_tui_loader.add_event state "error" detail

let apply_http_refresh_outcome ~hooks ~server_contact (state : T.state) ~mailbox = function
  | P.Refresh_workspace_unconfirmed
      { refresh_ticket; detail; unreachable; approval_ticket; latest_identity } ->
    if T.Http_refresh_order.is_current state.T.http_refresh_order refresh_ticket then
      apply_workspace_unconfirmed ~hooks state ~mailbox ~detail ~unreachable ~approval_ticket ~latest_identity
  | P.Refresh_surfaces results -> apply_http_surfaces ~hooks state ~mailbox results
  | P.Refresh_server_booting { refresh_ticket; identity; approval_ticket } ->
    apply_server_booting ~hooks state ~mailbox ~refresh_ticket ~identity ~approval_ticket
  | P.Refresh_account_server { refresh_ticket; version; approval_ticket } ->
    apply_account_server ~hooks ~server_contact state ~mailbox ~refresh_ticket ~version ~approval_ticket
