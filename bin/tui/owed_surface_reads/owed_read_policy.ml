module T = Masc_tui_types
module Owed_read = Masc_tui_owed_read
module Wake = Masc_tui_wake
module Mono = Masc_tui_wake.Mono
module Admission = Masc_tui_transport.Workspace_admission
module Event_streams = Masc_tui_transport.Event_streams
module Lane_addons = Masc_tui_lane_addons
module Dataset_ev = Masc.Workspace_dataset_event
module Machine_lane = Masc.Machine_lane
module Tui_decode = Masc.Tui_decode

let owe_held_calls_read (state : T.state) =
  state.T.held_calls_owed <- Owed_read.changed state.T.held_calls_owed

let owe_tool_modes_read (state : T.state) =
  state.T.tool_modes_owed <- Owed_read.changed state.T.tool_modes_owed

(* The turns are owed when the server says a Keeper's turns changed, when a
   preview changed that a surface on screen draws, on a revalidation or a
   resumed authority, and after any failed turns read.
   The debt is read only while something uses the answer
   ({!keeper_turns_in_use}); until then it stays owed. *)
let owe_keeper_turns_read (state : T.state) =
  state.T.keeper_turns_owed <- Owed_read.changed state.T.keeper_turns_owed

(* A waiting change marks its Keepers unverified and owes the list a read,
   which {!launch_owed_keeper_waiting} starts while the list is in use. *)
let owe_keeper_waiting_read ?change (state : T.state) =
  Option.iter (T.note_keeper_waiting_change state) change;
  state.T.keeper_waiting_owed <- Owed_read.changed state.T.keeper_waiting_owed

(* The Verification queue reads when the server says its request store, a
   run registry or the backlog changed, on a revalidation, and again after a
   failed read (RFC-0480 §3.4). *)
let owe_verification_read (state : T.state) =
  state.T.verification_owed <- Owed_read.changed state.T.verification_owed

(* The repository list reads when the server says the catalog changed, on a
   revalidation and on arrival, and again after a failed read (RFC-0480
   §3.4). *)
let owe_repositories_read (state : T.state) =
  state.T.repositories_owed <- Owed_read.changed state.T.repositories_owed

let pushed_read (state : T.state) source =
  Option.value ~default:Owed_read.settled (List.assoc_opt source state.T.pushed_reads)

let set_pushed_read (state : T.state) source read =
  state.T.pushed_reads <- (source, read) :: List.remove_assoc source state.T.pushed_reads

(* A bundle source in [pushed_sources] reads again when the server announces
   its change while its surface is on screen, and after a failed read
   (RFC-0480 §3.4). Entering the surface and a revalidation read it in the
   surface bundle. *)
let owe_pushed_read (state : T.state) source =
  set_pushed_read state source (Owed_read.changed (pushed_read state source))

(* The Usage view's provider windows and runtime quota standing read again
   when the server announces a usage report or a standing change; the
   provider history reads again on a usage report and once the UTC day a
   history request started on has ended. Both read on a revalidation and
   after a failed read (RFC-0480 §3.4). *)
let owe_provider_usage_reads (state : T.state) =
  owe_pushed_read state T.Surface_read_source.Runtime_quota;
  owe_pushed_read state T.Surface_read_source.Provider_history

let owe_provider_standing_read (state : T.state) =
  owe_pushed_read state T.Surface_read_source.Runtime_quota

(* The Usage view's Keeper usage reads again when the server announces that
   its cost window took or dropped a row, on a revalidation and after a
   failed read (RFC-0480 §3.4). *)
let owe_keeper_costs_read (state : T.state) =
  owe_pushed_read state T.Surface_read_source.Keeper_usage

let owe_provider_history_day (state : T.state) ~now =
  match state.T.provider_history_reread_at with
  | Some at when Wake.reached_wall Wake.Provider_history_day ~now ~at ->
      state.T.provider_history_reread_at <- None;
      owe_pushed_read state T.Surface_read_source.Provider_history
  | Some _ | None -> ()

(* Owed reads wait on this clock, so a wall-clock step cannot stretch a
   retry. *)
let keeper_execute_stream_reconnect_s = 2.0
let keeper_execute_stream_max_reconnect_s = 30.0


(* A failed read leaves its record waiting, whoever started it: a read on
   entering a surface, which the record never saw start, retries on the same
   clock as one it started. *)
let failed_read owed =
  Owed_read.failed ~retry_s:Event_streams.stream_reconnect_s
    ~max_retry_s:keeper_execute_stream_max_reconnect_s ~now:(Mono.now ())
    (Owed_read.answering owed)

(* A placeholder answer, whoever started the read, is read again on the
   failed read's clock; a change announced during it is read now. *)
let placeholder_read owed =
  Owed_read.placeholder ~retry_s:Event_streams.stream_reconnect_s
    ~max_retry_s:keeper_execute_stream_max_reconnect_s ~now:(Mono.now ())
    (Owed_read.answering owed)

(* runtime.toml reads when the server says it committed a text of it, on
   arrival and on a revalidation, and again after a failed read (RFC-0482
   L4). *)
let owe_runtime_config_read (state : T.state) =
  state.T.runtime_config_owed <- Owed_read.changed state.T.runtime_config_owed;
  (* The Usage view draws a quota row for each runtime the file declares. *)
  owe_pushed_read state T.Surface_read_source.Runtime_quota

(* The panes that draw runtime.toml. *)
let runtime_config_on_screen (state : T.state) =
  state.T.view = T.Config
  && (match state.T.config_pane with
      | T.Config_runtime | T.Config_models | T.Config_themes -> true
      | T.Config_prompts | T.Config_presets | T.Config_params | T.Config_voice -> false)

(* The connectors read again when [gate_connector_changed] arrives while they
   are on screen, and after a failed read (RFC-0480 §3.1). *)
let owe_connectors_read (state : T.state) =
  state.T.connectors_owed <- Owed_read.changed state.T.connectors_owed

(* Harness reads when the server says a verdict or a label was recorded, on a
   revalidation and on arrival, and again after a failed read (RFC-0480
   §3.4). *)
let owe_harness_read (state : T.state) =
  state.T.harness_owed <- Owed_read.changed state.T.harness_owed

let launch_owed_machine_live (state : T.state) ~mailbox =
  let launch machine visible owed in_flight set_owed launch_read =
    if not visible || state.T.machine_source <> machine then set_owed Owed_read.settled
    else begin
      let owed = if Option.is_none in_flight then Owed_read.abandoned owed else owed in
      set_owed owed;
      if Owed_read.due ~now:(Mono.now ()) owed then launch_read state ~mailbox
    end
  in
  launch Machine_lane.Msx (state.T.msx_open && not state.T.msx_menu_open)
    state.T.msx_live_owed state.T.msx_live_in_flight
    (fun owed -> state.T.msx_live_owed <- owed) Masc_tui_msx_control.Live_read.launch_msx_live_read;
  launch Machine_lane.Dos state.T.msx_open state.T.dos_live_owed state.T.dos_live_in_flight
    (fun owed -> state.T.dos_live_owed <- owed) Masc_tui_msx_control.Live_read.launch_dos_live_read

let launch_owed_browser_observation (state : T.state) ~mailbox ~pointer_active =
  match T.browser_lane_on_screen state with
  | None -> state.T.browser_observation_owed <- Owed_read.settled
  | Some view ->
      let owed = match view.T.Browser_lane_view.load with
        | T.Browser_lane_view.Loading _ -> state.T.browser_observation_owed
        | T.Browser_lane_view.Idle -> Owed_read.succeeded state.T.browser_observation_owed
        | T.Browser_lane_view.Failed _ ->
            (match state.T.browser_observation_owed with
             | Owed_read.Settled | Owed_read.Reading _ ->
                 failed_read state.T.browser_observation_owed
             | Owed_read.Owed _ | Owed_read.Waiting _ ->
                 state.T.browser_observation_owed)
        | T.Browser_lane_view.No_browser -> Owed_read.settled
      in
      state.T.browser_observation_owed <- owed;
      if T.server_authority_ready state
         && Owed_read.due ~now:(Mono.now ()) owed
         && not pointer_active then begin
        let viewport = if state.T.image_open then Option.map fst state.T.browser_viewport else None in
        match T.Browser_lane_view.observation_operation ?viewport view with
        | Some operation ->
            state.T.browser_observation_owed <- Owed_read.started owed;
            Masc_tui_surface_requests.Lane_browser_requests.launch_browser_lane state ~mailbox operation
        | None -> state.T.browser_observation_owed <- Owed_read.abandoned owed
      end

let launch_owed_lanes (state : T.state) ~mailbox =
  if state.T.view <> T.Lanes then
    state.T.lanes_owed <- Owed_read.settled
  else begin
    if not state.T.standalone_lanes_inflight then
      state.T.lanes_owed <- Owed_read.abandoned state.T.lanes_owed;
    if Owed_read.due ~now:(Mono.now ()) state.T.lanes_owed then
      Masc_tui_ops_requests.Lanes_activity_requests.launch_lanes_load state ~mailbox
  end

let launch_owed_lane_addons (state : T.state) ~mailbox =
  match state.T.lane_addons_owed with
  | None -> ()
  | Some ((owner, epoch), owed) ->
      (match state.T.lane_addons with
       | None -> state.T.lane_addons_owed <- None
       | Some view ->
           (match view.Lane_addons.screen with
            | Lane_addons.Overview | Lane_addons.Detail _ ->
                let matches =
                  match view.Lane_addons.screen with
                  | Lane_addons.Detail (open_id, incarnation) ->
                      String.equal owner open_id && String.equal epoch incarnation
                  | Lane_addons.Overview -> false
                in
                if not matches then state.T.lane_addons_owed <- None
                else begin
                  let busy =
                    Option.is_some view.Lane_addons.draft || Option.is_some view.Lane_addons.document_key
                    || Option.is_some view.Lane_addons.action_menu || Option.is_some view.Lane_addons.installer
                    || Option.is_some view.Lane_addons.subscription_panel || Option.is_some view.Lane_addons.evidence_prompt
                    || Option.is_some (Lane_addons.pending_action view)
                  in
                  if view.Lane_addons.loading || busy then ()
                  else begin
                    let owed = Owed_read.abandoned owed in
                    state.T.lane_addons_owed <- Some ((owner, epoch), owed);
                    if Owed_read.due ~now:(Mono.now ()) owed then
                      Masc_tui_surface_requests.Lane_browser_requests.launch_lane_addons state ~mailbox
                        ~target:(Lane_addons.Read_detail (owner, epoch))
                        Lane_addons.Inspect
                  end
                end))

let owe_machine_live_read (state : T.state) machine =
  let visible = match machine with
    | Machine_lane.Msx -> state.T.msx_open && not state.T.msx_menu_open
    | Machine_lane.Dos -> state.T.msx_open
  in
  if visible && state.T.machine_source = machine then
    match machine with
    | Machine_lane.Msx ->
        state.T.msx_live_owed <- Owed_read.changed state.T.msx_live_owed
    | Machine_lane.Dos ->
        state.T.dos_live_owed <- Owed_read.changed state.T.dos_live_owed

(* The fleet memory health reads on arrival, on a revalidation, when a row
   read cannot be merged, and again after a failed read. *)
let owe_memory_health_read (state : T.state) =
  state.T.memory_facts_owed <- Owed_read.changed state.T.memory_facts_owed;
  state.T.memory_activity_owed <- Owed_read.changed state.T.memory_activity_owed;
  state.T.memory_health_owed <- Owed_read.changed state.T.memory_health_owed

let owe_memory_world_read (state : T.state) =
  state.T.memory_world <- Masc_tui_memory_world.changed state.T.memory_world

(* The input pane shows the selected Keeper's turn records. A memory health
   answer may be about them: the fleet read, or a pushed row of that Keeper. *)
let owe_memory_input_read (state : T.state) =
  state.T.memory_input_owed <- Owed_read.changed state.T.memory_input_owed

(* A memory health push names the Keeper whose input was written. That
   Keeper's row is read on its own and merged into the fleet answer, so a
   Keeper that writes often costs one row per push. *)
let owe_memory_health_row (state : T.state) keeper =
  if Masc_tui_fetched.current_key state.T.memory_facts = Some keeper then
    state.T.memory_facts_owed <- Owed_read.changed state.T.memory_facts_owed;
  if Masc_tui_fetched.current_key state.T.memory_activity = Some keeper then
    state.T.memory_activity_owed <- Owed_read.changed state.T.memory_activity_owed;
  if not (List.exists (String.equal keeper) state.T.memory_health_rows_owed) then
    state.T.memory_health_rows_owed <- state.T.memory_health_rows_owed @ [ keeper ]

(* The Home Health line reads when the server announces it moved, on a
   revalidation, when the workspace authority changes, and again after a
   failed read (RFC-0480 §3.4). *)
let owe_overview_read (state : T.state) =
  state.T.overview_owed <- Owed_read.changed state.T.overview_owed

(* A dataset push owes a read to the surface that shows that dataset. *)
let owe_keeper_log_read (state : T.state) keeper =
  match T.keeper_log_target state with
  | Some selected when String.equal selected.Tui_decode.k_name keeper ->
      state.T.keeper_log_owed <- Owed_read.changed state.T.keeper_log_owed
  | Some _ | None -> ()

let owe_goal_projection_reads (state : T.state) =
  owe_pushed_read state T.Surface_read_source.Planning;
  owe_pushed_read state T.Surface_read_source.Overview_goals

let owe_runtime_surface_read (state : T.state) =
  state.T.runtime_surface_owed <- Owed_read.changed state.T.runtime_surface_owed

let owe_ask_followup_read (state : T.state) =
  state.T.ask_followup_owed <- Owed_read.changed state.T.ask_followup_owed

let owe_open_lane_addon_read (state : T.state) =
  match state.T.lane_addons with
  | Some { Lane_addons.screen = Lane_addons.Detail (open_id, incarnation); _ } ->
      let owed = match state.T.lane_addons_owed with
        | Some ((owner, epoch), owed) when String.equal owner open_id
            && String.equal epoch incarnation -> owed
        | Some _ | None -> Owed_read.settled
      in
      state.T.lane_addons_owed <-
        Some ((open_id, incarnation), Owed_read.changed owed)
  | Some { Lane_addons.screen = Lane_addons.Overview; _ } | None -> ()

let owe_push_owned_revalidation (state : T.state) =
  if state.T.view = T.Lanes then
    state.T.lanes_owed <- Owed_read.changed state.T.lanes_owed;
  owe_open_lane_addon_read state;
  owe_machine_live_read state state.T.machine_source;
  if Masc_tui_types.ask_followup_unfinished state then owe_ask_followup_read state

let owe_dataset_read (state : T.state) (dataset : Dataset_ev.dataset) =
  match dataset with
  | Dataset_ev.Repositories -> owe_repositories_read state
  | Dataset_ev.Backlog ->
      (* The feed handler reads Backlog's six reads itself: Work needs its
         mailbox, and the other five go with it. *)
      ()
  | Dataset_ev.Verification_requests -> owe_verification_read state
  | Dataset_ev.Keeper_metrics { keeper } -> owe_keeper_log_read state keeper
  | Dataset_ev.Harness_verdicts -> owe_harness_read state
  | Dataset_ev.Goals -> owe_goal_projection_reads state
  | Dataset_ev.Runtime_config -> owe_runtime_config_read state
  | Dataset_ev.Connectors -> owe_connectors_read state
  | Dataset_ev.Keeper_oauth_attempts { keeper } ->
      Masc_tui_types.owe_identity_login_read state keeper
  | Dataset_ev.Skill_activations { keeper } -> T.owe_skill_activations_read state keeper
  | Dataset_ev.Skill_catalog ->
      T.owe_tools_catalog_read state;
      T.owe_every_skill_usage_read state
  | Dataset_ev.Clients -> T.owe_clients_read state
  | Dataset_ev.Account_emails ->
      owe_pushed_read state T.Surface_read_source.Account_emails
  | Dataset_ev.Provider_usage -> owe_provider_usage_reads state
  | Dataset_ev.Provider_standing -> owe_provider_standing_read state
  | Dataset_ev.Keeper_costs -> owe_keeper_costs_read state
  | Dataset_ev.Workspace_health -> owe_overview_read state
  | Dataset_ev.Runtime_probe | Dataset_ev.Runtime_metrics ->
      owe_runtime_surface_read state
  | Dataset_ev.Machine_live { machine } -> owe_machine_live_read state machine
  | Dataset_ev.Browser_observation observation ->
      if Masc_tui_types.observer_browser_scope_of_state state = Some observation.Dataset_ev.scope then
        state.T.browser_observation_owed <- Owed_read.changed state.T.browser_observation_owed
  | Dataset_ev.Memory_health { keeper } -> owe_memory_health_row state keeper
  | Dataset_ev.World_memory -> owe_memory_world_read state
  | Dataset_ev.Dashboard_observation _ -> ()
  | Dataset_ev.Play_room _ | Dataset_ev.Play_seats ->
      state.T.play_room <- Option.map Masc_tui_play_room.revalidate state.T.play_room
  | (Dataset_ev.Lanes | Dataset_ev.Lane_addons _) as dataset ->
      let module Decision = Masc_tui_lane_read_decision in
      let addon = Option.bind state.T.lane_addons (fun (view : Lane_addons.t) ->
        match view.Lane_addons.screen with
        | Lane_addons.Detail (instance_id, _) -> Some instance_id
        | Lane_addons.Overview -> None)
      in
      (match Decision.of_views ~lanes:(state.T.view = T.Lanes) ~addon dataset with
       | Decision.Read_lanes -> state.T.lanes_owed <- Owed_read.changed state.T.lanes_owed
       | Decision.Read_addon instance_id ->
           (match state.T.lane_addons with
            | Some { Lane_addons.screen = Lane_addons.Detail (open_id, _); _ }
              when String.equal open_id instance_id -> owe_open_lane_addon_read state
            | Some { Lane_addons.screen = Lane_addons.Overview | Lane_addons.Detail _; _ } | None -> ())
       | Decision.Ignore -> ())

(* The durable async requests the Keepers list and Tools draw read under the
   same rules. *)
let owe_async_requests_read (state : T.state) =
  state.T.async_requests_owed <- Owed_read.changed state.T.async_requests_owed

let launch_surface_reads (state : T.state) ~mailbox (surface : T.surface) =
  if T.server_authority_ready state then
  match surface with
  | T.Lanes -> Masc_tui_ops_requests.Lanes_activity_requests.launch_lanes_load state ~mailbox
  | T.Clients -> T.owe_clients_read state
  (* The list draws nothing from the Keeper composite; Info and Secrets read
     it on entry and when it changes. Keeper_list reads memory health for its
     second-row axis cells (RFC-0511 A4). *)
  | T.Keepers T.Keeper_list ->
      owe_tool_modes_read state;
      owe_async_requests_read state;
      owe_memory_health_read state;
      owe_memory_world_read state;
      Masc_tui_surface_requests.Memory_repository_requests.launch_memory_health_load state ~mailbox
  | T.Keepers
      ( T.Keeper_detail | T.Keeper_logs | T.Keeper_calls | T.Keeper_message
      | T.Keeper_runtime_pick ) ->
      owe_tool_modes_read state;
      owe_async_requests_read state
  | T.Overview -> owe_held_calls_read state
  | T.Approvals ->
      Masc_tui_work_requests.Approval_gate_requests.launch_keeper_tool_approvals_load ~intent:T.Snapshot_read.Refresh state ~mailbox;
      Masc_tui_work_requests.Approval_gate_requests.launch_gate_snapshot_load ~intent:T.Snapshot_read.Refresh state ~mailbox
  | T.Schedules -> Masc_tui_work_requests.Schedule_call_requests.launch_schedules_load ~intent:T.Snapshot_read.Refresh state ~mailbox
  (* Arriving owes the queue a read as well as starting one: a read already
     in flight may have begun before a change that came while the queue was
     off screen, and the owed read follows it. *)
  | T.Verification ->
      owe_verification_read state;
      Masc_tui_ops_requests.Verification_requests.launch_verification_load state ~mailbox
  | T.Planning -> Masc_tui_ops_requests.Verification_requests.launch_verification_load state ~mailbox
  | T.Fusion ->
      let demand = Masc_tui_fusion_updates.After_change in
      Masc_tui_ops_requests.Fusion_requests.launch_fusion_runs_load ~demand state ~mailbox;
      (match state.T.fusion_mode with
       | T.Fusion_list -> ()
       | T.Fusion_detail run_id ->
           Masc_tui_work_actions.Detail_navigation.launch_fusion_detail_load ~demand state ~mailbox ~run_id
       | T.Fusion_historical_detail reference ->
           Masc_tui_work_actions.Detail_navigation.launch_fusion_historical_detail_load ~demand state ~mailbox ~reference)
  (* Arriving owes the fleet a read as well as starting one: a read already in
     flight may have begun before a write announced while the surface was off
     screen. Metrics shows the same health and owes it the same way. *)
  | T.Memory ->
      owe_memory_health_read state;
      owe_memory_world_read state;
      Masc_tui_surface_requests.Memory_repository_requests.launch_memory_health_load state ~mailbox
  | T.Repositories ->
      owe_repositories_read state;
      Masc_tui_surface_requests.Memory_repository_requests.launch_repositories_load state ~mailbox
  | T.Harness ->
      owe_harness_read state;
      Masc_tui_ops_requests.Overview_harness_requests.launch_harness_load state ~mailbox
  | T.Changes -> (
      match state.T.changes_keeper with
      | Some keeper_name -> Masc_tui_repo_changes.Workspace_file_changes.launch_file_changes_load state ~mailbox ~keeper_name
      | None -> ())
  | T.Connectors -> (
      match T.browser_lane_on_screen state with
      | None ->
          owe_connectors_read state;
          Masc_tui_surface_requests.Connector_volume_requests.launch_connectors_load state ~mailbox
      | Some _ -> Masc_tui_surface_requests.Lane_browser_requests.refresh_browser_lane state ~mailbox)
  | T.Runtime -> Masc_tui_surface_requests.Memory_repository_requests.launch_runtime_surface_load state ~mailbox ~force:false
  | T.Tools ->
      owe_async_requests_read state;
      T.owe_tools_reads state;
      Masc_tui_work_requests.Tools_task_requests.launch_tools_load state ~mailbox
  | T.Config -> (
      (* Each pane loads its own source. Named rather than left to an
         if/else chain: a pane added later should have to say where its data
         comes from instead of quietly inheriting runtime.toml's. *)
      match state.T.config_pane with
      | T.Config_prompts -> Masc_tui_surface_requests.Prompt_preset_requests.launch_prompts_load state ~mailbox
      | T.Config_presets -> Masc_tui_surface_requests.Prompt_preset_requests.launch_presets_load state ~mailbox
      | T.Config_params -> Masc_tui_surface_requests.Runtime_config_requests.launch_runtime_params_load state ~mailbox
      | T.Config_voice -> Masc_tui_work_requests.Voice_requests.launch_voice_config_load state ~mailbox
      | T.Config_runtime | T.Config_models | T.Config_themes ->
          owe_runtime_config_read state;
          Masc_tui_surface_requests.Runtime_config_requests.launch_runtime_config_load state ~mailbox)
  | T.Resources -> Masc_tui_resources_control.Resource_io_control.launch_resources_load state ~mailbox
  | T.Code -> Masc_tui_code_requests.launch_entries_load state ~host:Admission.server_peer_host ~deliver:(Admission.deliver_code state mailbox)
  | T.Metrics ->
      owe_memory_health_read state;
      Masc_tui_surface_requests.Memory_repository_requests.launch_memory_health_load state ~mailbox;
      Masc_tui_work_requests.Approval_gate_requests.launch_keeper_tool_approvals_load ~intent:T.Snapshot_read.Refresh state ~mailbox;
      Masc_tui_work_requests.Approval_gate_requests.launch_gate_snapshot_load ~intent:T.Snapshot_read.Refresh state ~mailbox;
      Masc_tui_work_requests.Approval_gate_requests.launch_keeper_tool_modes_load state ~mailbox
  | T.Acting | T.Board | T.System_logs -> ()
