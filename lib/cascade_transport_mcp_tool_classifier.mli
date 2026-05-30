(** MCP tool surface classification: which OAS tool names are exposed as
    public MCP, which require bound-actor authentication, and which name
    sets can be routed as runtime MCP. *)

val public_mcp_tool_names_of_oas_tools : Agent_sdk.Tool.t list -> string list
val public_mcp_tools_of_oas_tools : Agent_sdk.Tool.t list -> Agent_sdk.Tool.t list
val tool_names_are_public_mcp : string list -> bool
val runtime_mcp_tool_requires_bound_actor : string -> bool
val public_mcp_tool_requires_bound_actor : string -> bool

val tool_names_are_runtime_mcp
  :  ?allow_keeper_internal:bool
  -> string list
  -> bool
