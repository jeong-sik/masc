(** MCP Tool Definitions for MASC

    Single SSOT assembly reading embedded [config/tools/*.toml] declarations
    directly through {!Tool_definition_embedded} and domain-owned schema
    modules. *)

open Masc_domain

let code_query_schema : tool_schema =
  Tool_definition_embedded.schema "keeper_code_query"
;;

let receipt_wait_schema : tool_schema =
  Tool_definition_embedded.schema "keeper_receipt_wait"
;;

let skill_schema : tool_schema =
  Tool_definition_embedded.schema "keeper_skill"
;;

let identity_tool_search_schema : tool_schema =
  Tool_definition_embedded.schema "keeper_tool_search"
;;

let composition_result_schema : tool_schema =
  Tool_definition_embedded.schema "keeper_composition_result"
;;

let workspace_schemas : tool_schema list =
  Tool_schemas_workspace_core.schemas @ Tool_schemas_workspace_extra.schemas
;;

(** Tool schemas from modules that do NOT depend on Config
    (avoids Tools -> Config -> Tools cycle) *)
let raw_schemas : tool_schema list =
  workspace_schemas
  @ Tool_schemas_agent.schemas
  @ Tool_schemas_run.schemas
  @ Tool_schemas_schedule.schemas
  @ [ code_query_schema; receipt_wait_schema ]
  @ Tool_schemas_owned_job.schemas
  @ Masc_task_handlers.Tool_task_schemas.schemas
  @ Tool_schemas_wiki.schemas
;;

let all_schemas : tool_schema list = raw_schemas

(** All schemas including config-dependent module schemas *)
let all_schemas_extended =
  all_schemas
  @ Tool_schemas_misc.schemas
  @ Tool_schemas_local_runtime.schemas
;;

(** Get tool by name *)
let find_tool name =
  List.find_opt (fun (s : Masc_domain.tool_schema) -> String.equal s.name name) all_schemas_extended
;;
