(** Tools — MCP tool schema assembly for MASC.

    Collects schemas from individual modules into a unified list.
    Config.ml adds modules that depend on Config (Tool_control, Tool_a2a, Tool_misc).

    @since 0.1.0 *)

val retired_front_door_schema_names : string list
val filter_retired_front_door_schemas : Types.tool_schema list -> Types.tool_schema list
val raw_schemas : Types.tool_schema list
val all_schemas : Types.tool_schema list
val all_schemas_extended : Types.tool_schema list
val find_tool : string -> Types.tool_schema option
