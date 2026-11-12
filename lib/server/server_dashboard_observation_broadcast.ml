module Commit = Dashboard_observation_commit
module Input = Server_observation_input

let observation scope topic : Sse_event.Types.dashboard_observation_changed_payload =
  { topic; scope }
let workspace topics = List.map (observation `Workspace) topics
let keeper name topics = List.map (observation (`Keeper name)) topics

let observations = function
  | Input.Chat_operation { keeper = keeper_name; operation_id } ->
      [observation (`Operation { keeper_name; operation_id }) `Chat_operation]
  | Keeper { keeper = name; change = Phase _ } ->
      keeper name [`Keeper_composite; `Keeper_sandbox; `Keeper_runtime_trace]
      @ workspace [`Ide_presence]
  | Keeper { keeper = name; change = Composite | Row } ->
      keeper name [`Keeper_composite; `Keeper_sandbox; `Keeper_runtime_trace]
      @ workspace [`Ide_presence]
  | Keeper { keeper = name; change = Turn } ->
      keeper name [`Keeper_turns; `Keeper_composite; `Keeper_runtime_trace]
      @ workspace [`Telemetry]
  | Keeper { keeper = name; change = Turn_preview } ->
      keeper name [`Keeper_turns]
  | Keeper { keeper = name; change = Native_tasks | Child_content } ->
      keeper name [`Keeper_runtime_trace; `Keeper_sandbox]
  | Keeper { keeper = name; change = Memory_journal } ->
      keeper name [`Keeper_memory_health]
  | Keeper { keeper = name; change = Async_requests } ->
      keeper name [`Async_requests]
  | Keeper { keeper = name; change =
      Asks | Tool_approval_waits | Tool_approval_mode | Gate_settings
      | Event_queue | Waiting_inventory _ } ->
      keeper name [`Keeper_composite]
      @ workspace [`Gate]
  | Keeper { change = Chat; _ } -> []
  | Every_keeper_row -> workspace [`Keeper_composite; `Ide_presence]
  | Gate _ -> workspace [`Gate; `Gate_tool_events]
  | Connector _ -> workspace [`Gate]
  | Store Schedule -> workspace [`Scheduled_automation]
  | Store Pending_confirms -> workspace [`Gate]
  | Store Runtime_config -> workspace [`Runtime_resolved; `Skills; `Tools]
  | Store Skill_catalog -> workspace [`Skills; `Skill_usage; `Tools; `Tool_metrics]
  | Store (Tools | Lane_addon_exports) -> workspace [`Tools; `Tool_metrics]
  | Store Goals -> workspace [`Telemetry]
  | Execution_invalidated -> workspace [`Verification_requests; `Ide_presence]
  | Workspace_agent_signal _ -> workspace [`Ide_presence]
  | Workspace_messages _ -> []
  | Transport_state | Operator_judgment _ | Tool_host_attention -> []
  | Board -> []
  | Agent_core { keeper = name; change =
      Started | Completed | Failed | Yielded | Input_required | Tool_called
      | Tool_completed | Turn_completed } ->
      workspace [`Telemetry]
      @ (match name with Some name -> keeper name [`Keeper_runtime_trace] | None -> [])
  | Telemetry_sample -> workspace [`Telemetry; `Model_metrics]
  | Telemetry_gap _ -> workspace [`Telemetry; `Tool_metrics]
  | Keeper_tool_call { keeper = name } ->
      keeper name [`Keeper_runtime_trace]
      @ workspace [`Tool_metrics; `Gate_tool_events; `Ide_events; `Activity; `Telemetry]
  | Keeper_approval_audit { keeper = name; event = _ } ->
      keeper name [`Keeper_composite]
      @ workspace [`Gate; `Gate_tool_events; `Telemetry]
  | Dataset (Keeper_metrics { keeper = name }) ->
      keeper name [`Keeper_turns]
      @ workspace [`Model_metrics; `Telemetry]
  | Dataset (Skill_activations { keeper = name }) ->
      keeper name [`Skill_activations]
      @ workspace [`Skill_usage]
  | Dataset (Memory_health { keeper = name }) ->
      keeper name [`Keeper_memory_health]
  | Dataset Verification_requests -> workspace [`Verification_requests]
  | Dataset Runtime_probe -> workspace [`Runtime_probe]
  | Dataset Runtime_config -> workspace [`Runtime_resolved; `Tools; `Skills]
  | Dataset Skill_catalog -> workspace [`Tools; `Skills; `Skill_usage; `Tool_metrics]
  | Dataset (Provider_usage | Provider_standing | Account_emails) ->
      workspace [`Runtime_resolved]
  | Dataset (Runtime_metrics | Keeper_costs) -> workspace [`Model_metrics; `Telemetry]
  | Dataset Workspace_health -> workspace [`Health]
  | Dataset Clients -> workspace [`Ide_presence]
  | Dataset Repositories -> workspace [`Ide_presence; `Ide_events]
  | Dataset Connectors -> workspace [`Gate]
  | Dataset (Goals | Harness_verdicts | Lanes | Machine_live _ | Play_room _
      | Lane_addons _ | Browser_observation _ | Keeper_oauth_attempts _
      | World_memory | Play_seats | Dashboard_observation _) -> []
;;

module Changes = Server_workspace_invalidation.Make (struct
  type t = Commit.change
  let compare = Stdlib.compare
end)

let install ~state ~sw ~mono_clock =
  let ready, resolve_ready = Eio.Promise.create () in
  let initial = ref true in
  Server_observation_refresh.install_scoped ~state ~sw
    ~install:(fun ~scope ~sw ~is_current ->
      let base_path = scope.Mcp_server.config.base_path in
      let publish payload =
        if is_current () then (
          (* The series REST cache and native query reader share this exact
             family. Drop all filtered windows before either consumer wakes. *)
          if payload.Sse_event.Types.topic = `Tool_metrics
          then Server_dashboard_http_core_cache.invalidate_tool_metrics_series ~base_path;
          if payload.topic = `Activity || payload.topic = `Ide_events
          then Server_dashboard_http_core_cache.invalidate_ide_file_activity ~base_path;
          if payload.topic = `Activity then
            Dashboard_snapshot.invalidate_public_activity_events ~base_path;
          (match payload.scope with
           | `Keeper name ->
               if payload.topic = `Keeper_composite then
                 Server_dashboard_http_keeper_api_types.invalidate_keeper_composite_caches
                   ~base_path ~name;
               if payload.topic = `Keeper_runtime_trace then
                 Server_dashboard_http_keeper_api_types.invalidate_keeper_runtime_traces
                   ~base_path ~name
           | `Workspace ->
               if payload.topic = `Keeper_composite then
                 Server_dashboard_http_keeper_api_types.invalidate_workspace_keeper_composites ~base_path
           | `Operation _ -> ());
          if is_current () then
            Workspace_dataset_event.announce_dashboard_observation
              ~base_path ~scope:payload.scope payload.topic)
      in
      let enqueue = Changes.start ~sw ~mono_clock ~publish:(function
        | Commit.Process topic -> publish { Sse_event.Types.topic; scope = `Workspace }
        | Commit.Workspace { base_path = written_owner; payload } ->
            (* A writer may use a symlink or a relative spelling. Resolving
               that owner is deferred until this switch-owned publication;
               it must not suspend an already-committed store mutation. *)
            if is_current ()
               && String.equal (Fs_compat.realpath_lenient written_owner)
                    (Fs_compat.realpath_lenient base_path)
            then publish payload)
      in
      let unsubscribe_commits = Commit.subscribe enqueue in
      let unsubscribe_metrics = Tool_metrics.subscribe_written
          (fun () -> enqueue (Commit.Process `Tool_metrics)) in
      let unsubscribe_activity = Activity_graph.subscribe_written (fun ~base_path ->
        enqueue (Commit.Workspace {
          base_path; payload = observation `Workspace `Activity })) in
      Eio.Switch.on_release sw (fun () ->
        unsubscribe_commits ();
        unsubscribe_metrics ();
        unsubscribe_activity ());
      Input.subscribe ~sw ~base_path
        ~observer_instance_id:(Server_observer_scope.instance_id scope)
        (fun input ->
          List.iter (fun payload -> enqueue (Commit.Workspace { base_path; payload }))
            (observations input));
      if !initial && is_current () then (
        initial := false;
        Eio.Promise.resolve resolve_ready ()));
  Eio.Promise.await ready
;;
