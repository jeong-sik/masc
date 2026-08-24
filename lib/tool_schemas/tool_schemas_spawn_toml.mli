(** The four spawn tool declarations that live in
    [config/tools/masc_spawn*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot rather than advertising a partial spawn surface.
    [Tool_schemas_spawn] is the only consumer.

    [schema_of_name] stays inside: it is the reader these four are built with,
    and a caller that reaches for it is a caller naming a file this module
    should have named. *)

val start : Masc_domain.tool_schema
val read : Masc_domain.tool_schema
val wait : Masc_domain.tool_schema
val stop : Masc_domain.tool_schema
