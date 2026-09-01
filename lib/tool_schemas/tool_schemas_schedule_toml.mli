(** The four schedule tool declarations that moved to
    [config/tools/masc_schedule_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. [Tool_schemas_schedule] is the only consumer. *)

val create : Masc_domain.tool_schema
val list : Masc_domain.tool_schema
val get : Masc_domain.tool_schema
val update : Masc_domain.tool_schema
val cancel : Masc_domain.tool_schema
