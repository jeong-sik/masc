(** Mcp_server_eio_types -- Shared types for MCP server modules

    Extracted from mcp_server_eio.ml to avoid circular dependencies.
*)

type tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
  | Seat

let tool_profile_to_string = function
  | Full -> "full"
  | Managed_agent -> "managed_agent"
  | Operator_remote -> "operator_remote"
  | Seat -> "seat"
;;

let tool_profile_of_string = function
  | "full" -> Some Full
  | "managed_agent" -> Some Managed_agent
  | "operator_remote" -> Some Operator_remote
  | "seat" -> Some Seat
  | _ -> None
;;
