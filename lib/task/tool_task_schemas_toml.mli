(** The task tools whose declarations moved to [config/tools/masc_*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2), read from the
    binary-embedded config tree.

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial task surface, so a reader of these values never has to ask whether
    a schema loaded.

    [masc_add_task], [masc_batch_add_tasks] and [masc_transition] carry nested
    shapes: an object parameter with its own params, and an array whose object
    items declare required children. [test_task_tool_toml_parity] pins all
    seven against the literals this module replaced. *)

val task_history : Masc_domain.tool_schema
val tasks : Masc_domain.tool_schema
val update_priority : Masc_domain.tool_schema
val task_set_goal : Masc_domain.tool_schema
val add_task : Masc_domain.tool_schema
val batch_add_tasks : Masc_domain.tool_schema
val transition : Masc_domain.tool_schema
