(* MCP tool surface classification.

   Pulled out of [runtime_transport.ml] to shrink the godfile. Pure
   functions over Tool_catalog membership predicates - no shared state,
   no I/O. *)

let public_mcp_tool_names_of_oas_tools (tools : Agent_sdk.Tool.t list) =
  List.map (fun (tool : Agent_sdk.Tool.t) -> tool.schema.name) tools
;;

let public_mcp_tools_of_oas_tools (tools : Agent_sdk.Tool.t list) =
  List.filter
    (fun (tool : Agent_sdk.Tool.t) -> Tool_catalog.is_public_mcp tool.schema.name)
    tools
;;

let tool_names_are_public_mcp (tool_names : string list) =
  tool_names <> [] && List.for_all Tool_catalog.is_public_mcp tool_names
;;

let runtime_mcp_tool_requires_bound_actor tool_name =
  Tool_catalog.requires_actor_binding tool_name
;;

let public_mcp_tool_requires_bound_actor tool_name =
  Tool_catalog.is_public_mcp tool_name && runtime_mcp_tool_requires_bound_actor tool_name
;;

(* The Agent_internal surface was empty, so runtime-MCP eligibility reduces to
   public-MCP membership.  Surface deleted in the surface-cut refactor. *)
let tool_names_are_runtime_mcp (tool_names : string list) =
  tool_names <> [] && List.for_all Tool_catalog.is_public_mcp tool_names
;;
