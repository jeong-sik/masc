(** The four library tool declarations that moved to
    [config/tools/masc_library_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. [Tool_schemas_library] is the only consumer. *)

val list : Masc_domain.tool_schema
val read : Masc_domain.tool_schema
val add : Masc_domain.tool_schema
val search : Masc_domain.tool_schema
