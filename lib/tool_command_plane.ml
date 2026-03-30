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

type result = Tool_command_plane_support.result

let dispatch = Tool_command_plane_dispatch.dispatch

let schemas : Types.tool_schema list =
  Tool_command_plane_schemas_01.schemas
  @ Tool_command_plane_schemas_02.schemas
