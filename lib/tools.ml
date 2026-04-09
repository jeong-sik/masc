(** MCP Tool Definitions for MASC

    All schemas are now owned by individual modules.
    This file assembles cycle-free schemas; config.ml adds
    modules that depend on Config (Tool_control, Tool_a2a, Tool_misc). *)

open Types

(** Tool schemas from modules that do NOT depend on Config
    (avoids Tools -> Config -> Tools cycle) *)
let raw_schemas : tool_schema list =
  Tool_schemas_room_core.schemas
  @ Tool_schemas_room_extra.schemas
  @ Tool_schemas_inline.schemas
  @ Tool_schemas_plan.schemas
  @ Tool_schemas_agent.schemas
  @ Tool_schemas_auth.schemas
  @ Tool_schemas_worktree.schemas
  @ Tool_run.schemas
  @ Tool_task.schemas
  @ Tool_suspend.schemas
  @ Tool_relay.schemas
  @ Tool_handover.schemas
  @ Tool_code.schemas
  @ Tool_code_write.schemas
  @ Tool_library.schemas
  @ Tool_heartbeat.schemas

let all_schemas : tool_schema list = raw_schemas

(** All schemas including config-dependent module schemas *)
let all_schemas_extended =
  all_schemas
  @ Tool_schemas_control.schemas
  @ Tool_schemas_a2a.schemas
  @ Tool_schemas_misc.schemas
  @ Tool_keeper.schemas
  @ Tool_local_runtime.schemas @ Tool_shard.schemas
  @ Tool_autoresearch.schemas

(** Get tool by name *)
let find_tool name =
  List.find_opt (fun (s : Types.tool_schema) -> s.name = name) all_schemas_extended
