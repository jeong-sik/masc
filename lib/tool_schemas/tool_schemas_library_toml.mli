(** The four library tool declarations that moved to
    [config/tools/masc_library_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. Each value is the whole decoded file, so its
    [keeper_projection] travels with its schema. [Tool_schemas_library] is the
    only consumer. *)

val list : Tool_definition_toml.loaded
val read : Tool_definition_toml.loaded
val add : Tool_definition_toml.loaded
val search : Tool_definition_toml.loaded
