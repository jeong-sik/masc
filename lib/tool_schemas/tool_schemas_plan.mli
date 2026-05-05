(** Tool_schemas_plan — MCP tool schemas for [masc_plan_*] family.

    Data-only module — separates schema definitions from dispatch
    logic. *)

(** Planning tool schemas: [masc_plan_init], [masc_plan_update],
    [masc_plan_get], [masc_plan_delete], [masc_notes_append],
    [masc_notes_get], [masc_deliverable_write],
    [masc_deliverable_read]. *)
val schemas : Masc_domain.tool_schema list
