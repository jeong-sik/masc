
(** Tool_task_schemas — MCP tool schema definitions for task operations.

    Pure data module. Consumed by the MCP tool registry at startup to
    advertise task-related tool input/output shapes to clients.

    @since God file decomposition — extracted from [tool_task.ml] *)

(** Static list of [Masc_domain.tool_schema] records, one per task operation
    (masc_add_task, masc_claim_task, masc_claim_next, masc_transition,
    masc_task_state, …). Each entry carries [name], [description], and
    [input_schema] (JSON Schema object).

    Immutable at runtime. *)
val schemas : Masc_domain.tool_schema list
