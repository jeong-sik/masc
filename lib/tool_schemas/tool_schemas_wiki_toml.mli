(** The six wiki tool declarations that moved to
    [config/tools/masc_wiki_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization; a missing or undecodable file
    refuses the boot. Each value is the whole decoded file, so its
    [keeper_projection] travels with its schema. [Tool_schemas_wiki] is the
    only consumer. *)

val list : Tool_definition_toml.loaded
val read : Tool_definition_toml.loaded
val create : Tool_definition_toml.loaded
val update : Tool_definition_toml.loaded
val search : Tool_definition_toml.loaded
val lint : Tool_definition_toml.loaded
