(** MCP tool schemas for MASC room operations (facade).

    Concatenates schemas from {!Tool_schemas_coord_core} and
    {!Tool_schemas_coord_extra}. *)

val schemas : Masc_domain.tool_schema list
