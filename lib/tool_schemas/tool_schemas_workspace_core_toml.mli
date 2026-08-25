(** The three workspace-core tool declarations, moved to
    [config/tools/masc_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. [Tool_schemas_workspace_core] is the only consumer. *)

val status : Masc_domain.tool_schema
val check : Masc_domain.tool_schema
val heartbeat : Masc_domain.tool_schema
