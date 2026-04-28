(** MCP tool schemas for inline-dispatched tools (facade).

    Concatenates schemas from {!Tool_schemas_inline_coord},
    {!Tool_schemas_inline_infra}, and {!Tool_schemas_inline_episodes}. *)

val schemas : Types.tool_schema list
