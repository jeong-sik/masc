(** Tools — Single SSOT MCP tool schema assembly for MASC.

    Compiles embedded [config/tools/*.toml] declarations directly via
    {!Tool_definition_embedded} and aggregates domain-owned schema families. *)

val code_query_schema : Masc_domain.tool_schema
val receipt_wait_schema : Masc_domain.tool_schema
val skill_schema : Masc_domain.tool_schema
val identity_tool_search_schema : Masc_domain.tool_schema
val composition_result_schema : Masc_domain.tool_schema
val workspace_schemas : Masc_domain.tool_schema list
val raw_schemas : Masc_domain.tool_schema list
val all_schemas_extended : Masc_domain.tool_schema list
val find_tool : string -> Masc_domain.tool_schema option
