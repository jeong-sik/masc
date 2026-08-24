(** The four run tool declarations that moved to
    [config/tools/masc_run_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial run surface.
    [Tool_schemas_run] is the only consumer. *)

val init : Masc_domain.tool_schema
val plan : Masc_domain.tool_schema
val get : Masc_domain.tool_schema
val list : Masc_domain.tool_schema
