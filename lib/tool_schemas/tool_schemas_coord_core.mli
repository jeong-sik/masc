(** Tool_schemas_coord_core — MCP tool schemas for room management
    (core subset).

    Only schemas dispatched by {!Tool_coord} live here. Other
    schemas have been moved to their owning modules
    ({!Tool_task}, {!Tool_control}, {!Tool_suspend}, {!Tool_plan},

    Issue #8636: [assertion_kind_enum_strings] hand-mirrors
    {!Tool_coord.valid_assertion_strings}; the sync regression test
    [test_types.ml :: assertion_kind_ssot] catches drift. *)

(** Enum of valid [masc_check] assertion strings. *)
val assertion_kind_enum_strings : string list

(** Tool schemas: [masc_status], [masc_reset], [masc_workflow_guide],
    [masc_coordination_fsm_snapshot], [masc_check], [masc_heartbeat]. *)
val schemas : Masc_domain.tool_schema list
