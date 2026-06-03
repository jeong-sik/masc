(** MCP Tool Definitions for MASC

    All schemas are now owned by individual modules.
    This file assembles cycle-free schemas; config.ml adds
    modules that depend on Config (Tool_control, Tool_a2a, Tool_misc). *)

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
  (* Tool_schemas_plan.schemas moved into Tool_descriptors_gen
     (Tool_schemas_misc.schemas chain) via RFC-0057 PR-2 *)
  @ Tool_schemas_agent.schemas
  @ Tool_run.schemas
  @ Task.Tool.schemas
  @ Tool_library.schemas

let all_schemas : tool_schema list = raw_schemas

let task_tool_spec_read_only = [ "masc_task_history"; "masc_tasks" ]

let task_tool_required_permission = function
  | "masc_tasks" | "masc_task_history" -> Some Masc_domain.CanReadState
  | "masc_add_task" | "masc_batch_add_tasks" -> Some Masc_domain.CanAddTask
  | "masc_claim_next" -> Some Masc_domain.CanClaimTask
  | "masc_transition" | "masc_update_priority" -> Some Masc_domain.CanCompleteTask
  | _ -> None

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
       Tool_spec.register
         (Tool_spec.create
            ~name:s.name
            ~description:s.description
            ~module_tag:Tool_dispatch.Mod_task
            ~input_schema:s.input_schema
            ~handler_binding:Tag_dispatch
            ~is_read_only:(List.mem s.name task_tool_spec_read_only)
            ~is_idempotent:(List.mem s.name task_tool_spec_read_only)
            ?required_permission:(task_tool_required_permission s.name)
            ()))
    Task.Tool.schemas

(** All schemas including config-dependent module schemas *)
let all_schemas_extended =
  (all_schemas
   @ Tool_schemas_misc.schemas
   @ Tool_local_runtime.schemas @ Tool_shard.schemas)
  |> dedupe_schemas_by_name

(** Get tool by name *)
let find_tool name =
  List.find_opt (fun (s : Masc_domain.tool_schema) -> s.name = name) all_schemas_extended
