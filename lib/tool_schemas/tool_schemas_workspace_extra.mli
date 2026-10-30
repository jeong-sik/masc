(** Tool_schemas_workspace_extra — MCP tool schemas for shared Goal
    Store operations (list / upsert / review).

    Consumed by {!Tool_schemas_workspace}, {!Tools}, and
    {!Keeper_tool_surfaces} to expose [masc_goal_*] on alignment
    surfaces. *)

val schemas : Masc_domain.tool_schema list
