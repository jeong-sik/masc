(** Tool_schemas_coord_extra — MCP tool schemas for shared Goal
    Store operations (list / upsert / review).

    Consumed by {!Tool_schemas_coord}, {!Tools}, and
    {!Agent_tool_surfaces} to expose [masc_goal_*] on coordinating
    surfaces. *)

val schemas : Masc_domain.tool_schema list
