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

let status_schema = Tool_definition_embedded.schema "masc_status"
let check_schema = Tool_definition_embedded.schema "masc_check"
let heartbeat_schema = Tool_definition_embedded.schema "masc_heartbeat"

let schema = function
  | Status -> status_schema
  | Check -> check_schema
  | Heartbeat -> heartbeat_schema
;;

let tool_name operation = (schema operation).name

let operation_of_tool_name value =
  List.find_opt (fun operation -> String.equal value (tool_name operation)) operations
;;

let schemas : tool_schema list = List.map schema operations
