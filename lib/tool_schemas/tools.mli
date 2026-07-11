(** Tools — MCP tool schema assembly for MASC.

    Collects schemas from individual modules into a unified list.
    Config.ml adds modules that depend on Config (Tool_misc).

    @since 0.1.0 *)

val raw_schemas : Masc_domain.tool_schema list
val all_schemas : Masc_domain.tool_schema list
val all_schemas_extended : Masc_domain.tool_schema list
val find_tool : string -> Masc_domain.tool_schema option
