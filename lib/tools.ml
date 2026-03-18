(** MCP Tool Definitions for MASC *)

open Types

(** All MASC tool schemas *)
let raw_schemas : tool_schema list =
  Tools_schemas_01.schemas
  @ Tools_schemas_02.schemas
  @ Tools_schemas_03.schemas
  @ Tools_schemas_04.schemas
  @ Tools_schemas_05.schemas
  @ Tools_schemas_06.schemas
  @ Tools_schemas_07.schemas
  @ Tools_schemas_08.schemas
  @ Tools_schemas_09.schemas
  @ Tools_schemas_10.schemas
  @ Tools_schemas_11.schemas

let all_schemas : tool_schema list = raw_schemas

(** All schemas including Perpetual Agent Runtime tools *)
let all_schemas_with_perpetual =
  all_schemas @ Tool_keeper.schemas
  @ Tool_operator.schemas @ Tool_llama.schemas @ Tool_command_plane.schemas @ Tool_goals.schemas
  @ Tool_team_session.schemas @ Tool_voice.schemas @ Tool_shard.schemas
  @ Tool_autoresearch.schemas
  @ Tool_compact.schemas
  (* Removed from surface (0 calls in 6-day audit):
     Tool_perpetual, Tool_code_swarm, Tool_notifications, Tool_agent_timeline *)

(** Get tool by name *)
let find_tool name =
  List.find_opt (fun s -> s.name = name) all_schemas_with_perpetual
