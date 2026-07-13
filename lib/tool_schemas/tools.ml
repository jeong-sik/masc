(** MCP Tool Definitions for MASC

    All schemas are now owned by individual modules.
    This file assembles cycle-free schemas; config.ml adds
    modules that depend on Config (Tool_control, Tool_misc). *)

open Masc_domain

module StringSet = Set_util.StringSet

let dedupe_schemas_by_name (schemas : tool_schema list) =
  let unique, _ =
    List.fold_left
      (fun (acc, seen) (schema : tool_schema) ->
        if StringSet.mem schema.name seen then (acc, seen)
        else (schema :: acc, StringSet.add schema.name seen))
      ([], StringSet.empty) schemas
  in
  List.rev unique

(** Tool schemas from modules that do NOT depend on Config
    (avoids Tools -> Config -> Tools cycle) *)
let raw_schemas : tool_schema list =
  Tool_schemas_workspace_core.schemas
  @ Tool_schemas_workspace_extra.schemas
  @ Tool_schemas_inline.schemas
  @ Tool_schemas_agent.schemas
  @ Tool_schemas_run.schemas
  @ Tool_schemas_schedule.schemas
  @ Masc_task_handlers.Tool_task_schemas.schemas
  @ Tool_schemas_library.schemas
  @ Tool_schemas_recurring.schemas

let all_schemas : tool_schema list = raw_schemas

(** All schemas including config-dependent module schemas *)
let all_schemas_extended =
  (all_schemas
   @ Tool_schemas_misc.schemas
   @ Tool_schemas_local_runtime.schemas)
  |> dedupe_schemas_by_name

(** Get tool by name *)
let find_tool name =
  List.find_opt (fun (s : Masc_domain.tool_schema) -> s.name = name) all_schemas_extended
