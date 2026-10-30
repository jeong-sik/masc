(** The four spawn tool declarations, read from
    [config/tools/keeper_spawn*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial spawn surface, so a
    reader of these values never has to ask whether a schema loaded.
    [Tool_schemas_spawn] is the only consumer. *)

val start : Masc_domain.tool_schema
val read : Masc_domain.tool_schema
val wait : Masc_domain.tool_schema
val stop : Masc_domain.tool_schema
