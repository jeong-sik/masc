module Input = Server_observation_input

type surface = Execution_trust | Transport_health

let affects_execution_trust = function
  | Input.Keeper { change =
      (Phase _ | Composite | Row | Turn | Tool_approval_waits
      | Tool_approval_mode | Gate_settings | Event_queue | Waiting_inventory _); _ }
  | Every_keeper_row | Gate _ | Connector _
  | Keeper_tool_call _ | Keeper_approval_audit _ -> true
  | Telemetry_gap { source = Some Execution_receipt; _ } -> true
  | Store (Runtime_config | Tools) -> true
  | Dataset (Runtime_config | Connectors | Runtime_probe | Provider_standing
      | Runtime_metrics) -> true
  | Keeper { change =
      (Turn_preview | Chat | Native_tasks | Child_content | Memory_journal | Async_requests | Asks); _ }
  | Store (Schedule | Pending_confirms | Goals | Skill_catalog | Lane_addon_exports)
  | Dataset (Repositories | Verification_requests | Harness_verdicts | Goals
      | Keeper_metrics _ | Skill_activations _ | Skill_catalog | Clients
      | Account_emails | Provider_usage | Keeper_costs | Workspace_health
      | Lanes | Machine_live _ | Play_room _ | Lane_addons _
      | Browser_observation _ | Keeper_oauth_attempts _ | Memory_health _
      | World_memory | Play_seats | Dashboard_observation _)
  | Telemetry_gap { source = None; _ }
  | Telemetry_gap { source = Some (Keeper_metric | Agent_event | Tool_call_io
      | Trajectory_tool_call | Tool_usage | Agent_core_event | Goal_event | Tool_metric); _ }
  | Chat_operation _ | Agent_core _ | Board | Execution_invalidated | Telemetry_sample
  | Transport_state | Workspace_agent_signal _ | Workspace_messages _ -> false
;;

let affects_transport_health = function
  | Input.Dataset (Dashboard_observation _) -> false
  | Dataset (Repositories | Verification_requests | Harness_verdicts | Goals
      | Runtime_config | Connectors | Keeper_metrics _ | Skill_activations _
      | Skill_catalog | Clients | Account_emails | Provider_usage | Provider_standing
      | Keeper_costs | Workspace_health | Runtime_probe | Runtime_metrics | Lanes
      | Machine_live _ | Play_room _ | Lane_addons _ | Browser_observation _
      | Keeper_oauth_attempts _ | Memory_health _ | World_memory | Play_seats)
  | Keeper _ | Every_keeper_row | Chat_operation _ | Gate _ | Connector _ | Store _
  | Board | Execution_invalidated | Agent_core _ | Telemetry_sample | Transport_state
  | Telemetry_gap _ | Keeper_tool_call _ | Keeper_approval_audit _
  | Workspace_agent_signal _ | Workspace_messages _ -> true
;;

let affects = function
  | Execution_trust -> affects_execution_trust
  | Transport_health -> affects_transport_health
;;

type 'a generation = {
  config : Proactive_refresh.config;
  compute : unit -> 'a;
  on_result : 'a -> unit;
  next_deadline : 'a -> float option;
}

let is_current state (scope : Mcp_server.workspace_scope) =
  Mcp_server.Workspace_scope_epoch.equal scope.epoch
    (Mcp_server.workspace_scope state).epoch
;;

let install_scoped ~state ~sw ~install =
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec follow_scope () =
      let scope = Mcp_server.workspace_scope state in
      Eio.Fiber.first
        (fun () ->
          Eio.Switch.run (fun generation_sw ->
            install ~scope ~sw:generation_sw
              ~is_current:(fun () -> is_current state scope);
            Eio.Fiber.await_cancel ()))
        (fun () -> Eio.Promise.await (Mcp_server.workspace_scope_replaced scope));
      follow_scope ()
    in
    follow_scope ())
;;

let start ~state ~sw ~clock ~surface ~generation =
  install_scoped ~state ~sw ~install:(fun ~scope ~sw:generation_sw ~is_current ->
    let changes = Eio.Stream.create 1 in
    let mu = Stdlib.Mutex.create () in
    Input.subscribe ~sw:generation_sw ~base_path:scope.config.base_path
      ~observer_instance_id:(Server_observer_scope.instance_id scope)
      (fun input ->
        if affects surface input then
          Stdlib.Mutex.protect mu (fun () ->
            if Eio.Stream.is_empty changes then Eio.Stream.add changes ()));
    let worker = generation ~scope ~sw:generation_sw in
    let config =
      { worker.config with on_failure =
          Option.map (fun on_failure failure ->
            if is_current () then on_failure failure)
            worker.config.on_failure }
    in
    Proactive_refresh.start_on_change_or_deadline ~sw:generation_sw
      ~clock ~changes ~config ~compute:worker.compute
      ~next_deadline:worker.next_deadline
      ~on_result:(fun value ->
        if is_current () then worker.on_result value))
;;
