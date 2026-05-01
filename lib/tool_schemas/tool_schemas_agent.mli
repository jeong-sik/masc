(** Tool_schemas_agent — MCP tool schemas for [masc_agent*] family.

    Legacy A2A agent-card and collaboration-graph front doors are retired
    and intentionally absent from this schema list. *)

(** Tool schemas: [masc_agents], [masc_agent_update],
    [masc_agent_fitness], [masc_register_capabilities], [masc_get_metrics]. *)
val schemas : Types.tool_schema list
