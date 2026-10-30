(** MCP tool schemas for workspace management operations (core).

    Only schemas dispatched by Tool_workspace remain here.
    Other schemas live in their owning modules. *)

open Masc_domain

type operation =
  | Status
  | Check
  | Heartbeat
[@@deriving enumerate]

let operations = all_of_operation

let schema = function
  | Status -> Tool_schemas_workspace_core_toml.status
  | Check -> Tool_schemas_workspace_core_toml.check
  | Heartbeat -> Tool_schemas_workspace_core_toml.heartbeat
;;

let tool_name operation = (schema operation).name

let operation_of_tool_name value =
  List.find_opt (fun operation -> String.equal value (tool_name operation)) operations
;;

let schemas : tool_schema list = List.map schema operations
