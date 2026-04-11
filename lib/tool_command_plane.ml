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
           ()))
    schemas
