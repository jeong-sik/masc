(** The operator tool declarations, moved to
    [config/tools/masc_operator_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. [Operator_tool] is the only consumer. *)

val quarantine_requeue : Masc_domain.tool_schema
val task_recovery_resolve : Masc_domain.tool_schema
val confirm : Masc_domain.tool_schema
val judgment_write : Masc_domain.tool_schema
