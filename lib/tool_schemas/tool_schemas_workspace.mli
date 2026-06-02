(** MCP tool schemas for MASC workspace operations (facade).

    Concatenates schemas from {!Tool_schemas_workspace_core} and
    {!Tool_schemas_workspace_extra}. *)

val schemas : Masc_domain.tool_schema list
