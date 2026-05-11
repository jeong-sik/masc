(** MCP Tool Definitions for MASC

    All schemas are now owned by individual modules.
    This file assembles cycle-free schemas; config.ml adds
    modules that depend on Config (Tool_control, Tool_a2a, Tool_misc). *)

open Masc_domain

let retired_front_door_schema_names =
  [
  ]

let filter_retired_front_door_schemas (schemas : tool_schema list) =
  List.filter
    (fun (schema : tool_schema) ->
      not (List.mem schema.name retired_front_door_schema_names))
    schemas

(** Tool schemas from modules that do NOT depend on Config
    (avoids Tools -> Config -> Tools cycle) *)
let raw_schemas : tool_schema list =
  Tool_schemas_coord_core.schemas
  @ Tool_schemas_coord_extra.schemas
  @ Tool_schemas_inline.schemas
  (* Tool_schemas_plan.schemas moved into Tool_descriptors_gen
     (Tool_schemas_misc.schemas chain) via RFC-0057 PR-2 *)
  @ Tool_schemas_agent.schemas
  @ Tool_schemas_worktree.schemas
  @ Tool_run.schemas
  @ Tool_task.schemas
  @ Tool_suspend.schemas
  @ Tool_code.schemas
  @ Tool_code_write.schemas
  @ Tool_library.schemas

let all_schemas : tool_schema list = raw_schemas

(** All schemas including config-dependent module schemas *)
let all_schemas_extended =
  filter_retired_front_door_schemas
    (all_schemas
    @ Tool_schemas_misc.schemas
    @ Keeper_types.schemas
    @ Tool_local_runtime.schemas @ Tool_shard.schemas
    @ Tool_autoresearch.schemas)

(** Get tool by name *)
let find_tool name =
  List.find_opt (fun (s : Masc_domain.tool_schema) -> s.name = name) all_schemas_extended
