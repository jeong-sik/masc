module Input = Server_observation_input
module Commit = Dashboard_observation_commit

type component = Shell | Tools | Telemetry

let components_of_topic : Sse_event.Types.dashboard_observation_topic -> component list = function
  | `Runtime_resolved | `Runtime_probe -> [Shell; Tools]
  | `Ide_presence -> [Shell]
  | `Tools | `Tool_metrics | `Skill_usage -> [Tools; Telemetry]
  | `Telemetry -> [Telemetry]
  | `Logs | `Health | `Attribution | `Keeper_composite | `Keeper_runtime_trace
  | `Keeper_sandbox | `Keeper_turns | `Keeper_memory_health | `Model_metrics
  | `Runtime_observables | `Scheduled_automation | `Skills | `Async_requests
  | `Skill_activations | `Published_artifacts | `Artifact_checks
  | `Verification_requests | `Verification_specs | `Tlc_results | `Activity
  | `Ide_events | `Gate | `Gate_tool_events | `Chat_operation -> []
;;

let components_of_input input =
  let extra = match input with
    | Input.Keeper {change = Asks | Tool_approval_waits | Tool_approval_mode
        | Gate_settings | Event_queue | Waiting_inventory _; _}
    | Gate _ | Connector _ -> [Tools]
    | Execution_invalidated -> [Shell; Telemetry]
    | Keeper {change = Phase _ | Composite | Row; _}
    | Every_keeper_row -> [Telemetry]
    | Keeper {change = Turn | Turn_preview | Chat
        | Native_tasks | Child_content | Memory_journal | Async_requests; _}
    | Dataset _ | Chat_operation _ | Store _ | Board
    | Agent_core _ | Telemetry_sample | Telemetry_gap _ | Keeper_tool_call _
    | Keeper_approval_audit _ | Workspace_agent_signal _ | Workspace_messages _
    | Transport_state -> []
  in
  Server_dashboard_observation_broadcast.observations input
  |> List.concat_map (fun payload -> components_of_topic payload.Sse_event.Types.topic)
  |> List.append extra |> List.sort_uniq Stdlib.compare
;;

type readers = {
  shell : light:bool -> Workspace.config -> Yojson.Safe.t;
  tools : Workspace.config -> Dashboard_snapshot.tools_result;
  telemetry : now:float -> Workspace.config -> Telemetry_unified.summary_observation;
}

let readers = ref {
  shell = (fun ~light config -> Server_dashboard_http_core.dashboard_shell_payload_json ~light config);
  tools = (fun config -> Server_dashboard_http_runtime_info.dashboard_tools_http_result
    ~read_policy:Dashboard_projection_read.Current config);
  telemetry = (fun ~now config ->
    let base_path = config.Workspace.base_path in
    Telemetry_unified.observe_summary ~now ~masc_root:(Workspace.masc_dir config)
      ~keeper_keepalive_interval_s:(Runtime_params.get Runtime_settings.keeper_keepalive_interval_sec |> float_of_int)
      ~keeper_metric_producer_active:(Keeper_status_runtime.keeper_metric_producer_active ~base_path) ());
}

module Commit_changes = Server_workspace_invalidation.Make (struct
  type t = Commit.change
  let compare = Stdlib.compare
end)

exception Tools_read_failed
exception Telemetry_read_failed
type tools_read =
  | Awaiting_tools
  | Failed_tools
  | Read_tools of Dashboard_snapshot.tools_update

let install ~state ~sw ~clock ~mono_clock ~on_shell_published =
  Server_observation_refresh.install_scoped ~state ~sw
    ~install:(fun ~scope ~sw ~is_current ->
      let config = scope.Mcp_server.config in
      let base_path = config.base_path in
      let publisher = Dashboard_snapshot.activate ~config ~is_current in
      Eio.Switch.on_release sw (fun () -> Dashboard_snapshot.retire publisher);
      let mutex = Stdlib.Mutex.create () in
      let shell_changes = Eio.Stream.create 1
      and tools_changes = Eio.Stream.create 1
      and telemetry_changes = Eio.Stream.create 1 in
      let signal component =
        let changes = match component with
          | Shell -> shell_changes | Tools -> tools_changes | Telemetry -> telemetry_changes in
        Stdlib.Mutex.protect mutex (fun () ->
          if Eio.Stream.is_empty changes then Eio.Stream.add changes ())
      in
      let enqueue_commit = Commit_changes.start ~sw ~mono_clock ~publish:(function
        | Commit.Process topic -> if is_current () then List.iter signal (components_of_topic topic)
        | Commit.Workspace {base_path = owner; payload} ->
          if is_current () && String.equal (Fs_compat.realpath_lenient owner)
              (Fs_compat.realpath_lenient base_path)
          then if is_current () then List.iter signal (components_of_topic payload.topic)) in
      let unsubscribe_commits = Commit.subscribe (fun change ->
        let topic = match change with Commit.Process topic -> topic
          | Commit.Workspace {payload; _} -> payload.topic in
        if components_of_topic topic <> [] then enqueue_commit change) in
      let unsubscribe_metrics = Tool_metrics.subscribe_written (fun () ->
        enqueue_commit (Commit.Process `Tool_metrics)) in
      Eio.Switch.on_release sw (fun () -> unsubscribe_commits (); unsubscribe_metrics ());
      Input.subscribe ~sw ~base_path
        ~observer_instance_id:(Server_observer_scope.instance_id scope)
        (fun input -> List.iter signal (components_of_input input));
      let announce topic = if is_current () then
        Workspace_dataset_event.announce_dashboard_observation ~base_path ~scope:`Workspace topic in
      let worker_config label timeout_s =
        { (Proactive_refresh.default_config ~label
            ~interval_s:Server_observation_retry.initial_delay_s) with timeout_s } in
      let offload work = Pool_work.submit (Pool_work.cpu ~name:__FUNCTION__ work) in
      Proactive_refresh.start_on_change ~sw ~clock ~changes:shell_changes
        ~config:(worker_config "dashboard Shell sources" Env_config_runtime.Dashboard.shell_timeout_sec)
        ~compute:(fun () -> offload (fun () ->
          let shell = (!readers).shell ~light:false config in
          let shell_light = (!readers).shell ~light:true config in
          shell, shell_light))
        ~on_result:(fun (shell, shell_light) -> if is_current () then (
          Dashboard_snapshot.publish_shell publisher ~shell ~shell_light;
          on_shell_published ~scope ~shell ~shell_light;
          announce `Runtime_resolved));
      Proactive_refresh.start_on_change ~sw ~clock ~changes:tools_changes
        ~config:(worker_config "dashboard Tools sources" Server_dashboard_http_core_cache.dashboard_request_timeout_s)
        ~compute:(fun () -> offload (fun () -> match (!readers).tools config with
          | Dashboard_snapshot.Tools_ready json ->
              Read_tools (Dashboard_snapshot.prepare_tools publisher json)
          | Tools_pending _ -> Awaiting_tools
          | Tools_error _ -> Failed_tools))
        ~on_result:(function
          | Read_tools update -> if is_current () then (
              Dashboard_snapshot.publish_tools update;
              Server_dashboard_http_runtime_info.invalidate_dashboard_tools ~base_path;
              announce `Tools)
          | Awaiting_tools -> ()
          | Failed_tools -> if is_current () then raise Tools_read_failed);
      Proactive_refresh.start_on_change_or_deadline ~sw ~clock ~changes:telemetry_changes
        ~config:(worker_config "dashboard telemetry sources" Server_dashboard_http_core_cache.dashboard_request_timeout_s)
        ~compute:(fun () -> offload (fun () -> (!readers).telemetry ~now:(Eio.Time.now clock) config))
        ~next_deadline:(fun observation -> observation.Telemetry_unified.next_change_at_unix)
        ~on_result:(fun observation -> if is_current () then (
          Dashboard_snapshot.publish_telemetry publisher observation.json;
          announce `Telemetry;
          if observation.read_failed then raise Telemetry_read_failed)))
;;

module For_testing = struct
  type nonrec readers = readers = {
    shell : light:bool -> Workspace.config -> Yojson.Safe.t;
    tools : Workspace.config -> Dashboard_snapshot.tools_result;
    telemetry : now:float -> Workspace.config -> Telemetry_unified.summary_observation;
  }
  let with_readers replacement f =
    let previous = !readers in readers := replacement;
    Fun.protect ~finally:(fun () -> readers := previous) f
end
