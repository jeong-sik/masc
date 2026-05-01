(** Tool_schemas_agent — MCP tool schemas for [masc_agent*] family.

    [masc_tool_schemas] only depends on [masc_types], so enum strings
    that must stay in sync with {!Tool_agent} (which lives higher up
    the dep tree) are hand-mirrored here. The
    [test_types.ml :: agent_tool_variants_ssot] regression test catches
    drift between the two sides.

    Issues: #8501 (mirror pattern), #8372 (agent_status enum derivation),
    #8467/#8480/#8484/#8490/#8493 (related mirror+sync pattern). *)

(** Allowed values for [masc_agent_card] [action]: ["get" | "refresh"].
    Mirror of [Tool_agent.valid_agent_card_action_strings]. *)

(** Allowed values for [masc_collaboration_graph] [format]:
    ["text" | "json"]. Mirror of
    [Tool_agent.valid_collaboration_format_strings]. *)

(** Tool schemas: [masc_agents], [masc_agent_update],
    [masc_agent_fitness], [masc_register_capabilities],
    [masc_get_metrics]. *)
val schemas : Types.tool_schema list
