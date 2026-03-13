(** MCP Tool Definitions for MASC *)

open Types

(** All MASC tool schemas *)
let raw_schemas : tool_schema list = 
  Tool_schemas_auth.schemas @ Tool_schemas_board.schemas @ Tool_schemas_worktree.schemas @ Tool_schemas_agent.schemas @ Tool_schemas_plan.schemas @ Tool_schemas_debate.schemas @ Tool_schemas_consensus.schemas @ Tool_schemas_execution.schemas @ Tool_schemas_room.schemas @ Tool_schemas_portal.schemas @ Tool_schemas_core.schemas

let all_schemas : tool_schema list = raw_schemas

(** All schemas including Perpetual Agent Runtime tools *)
let all_schemas_with_perpetual =
  all_schemas @ Tool_perpetual.schemas @ Tool_keeper.schemas
  @ Tool_operator.schemas @ Tool_llama.schemas @ Tool_command_plane.schemas @ Tool_goals.schemas
  @ Tool_team_session.schemas @ Tool_voice.schemas @ Tool_shard.schemas
  @ Tool_notifications.schemas

(** Get tool by name *)
let find_tool name =
  List.find_opt (fun s -> s.name = name) all_schemas_with_perpetual
