type ('clock, 'net) context = ('clock, 'net) Tool_command_plane_support.context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t option;
  clock : 'clock Eio.Time.clock option;
  net : 'net option;
  mcp_state : Mcp_server.server_state option;
  mcp_session_id : string option;
  auth_token : string option;
}

type tool_result = Tool_command_plane_support.tool_result

let dispatch = Tool_command_plane_dispatch.dispatch

let schemas : Types.tool_schema list =
  Tool_command_plane_schemas_01.schemas
  @ Tool_command_plane_schemas_02.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

(* Destructive annotations aligned with Tool_catalog.explicit_metadata. *)
let _destructive_tools = [ "masc_operation_stop" ]
let _non_destructive_tools = [ "masc_operation_pause" ]

let tool_required_permission = function
  | "masc_unit_list" | "masc_operation_status" | "masc_dispatch_plan"
  | "masc_policy_status" | "masc_observe_topology"
  | "masc_observe_operations" | "masc_observe_swarm"
  | "masc_observe_alerts" | "masc_observe_capacity"
  | "masc_observe_traces" | "masc_intent_status"
  | "masc_intent_forecast" ->
      Some Types.CanReadState
  | "masc_unit_define" | "masc_unit_reparent" | "masc_unit_reassign"
  | "masc_operation_start" | "masc_operation_checkpoint"
  | "masc_operation_pause" | "masc_operation_resume"
  | "masc_operation_stop" | "masc_operation_finalize"
  | "masc_dispatch_assign" | "masc_dispatch_rebalance"
  | "masc_dispatch_escalate" | "masc_dispatch_recall"
  | "masc_dispatch_tick" | "masc_policy_approve"
  | "masc_policy_deny" | "masc_policy_update"
  | "masc_intent_create" | "masc_intent_update" ->
      Some Types.CanBroadcast
  | "masc_policy_freeze_unit" | "masc_policy_kill_switch" ->
      Some Types.CanAdmin
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      let is_destructive = List.mem s.name _destructive_tools in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_command_plane
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_destructive
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
