(** The surface tools, read from [config/tools/keeper_surface_*.toml] and
    [config/tools/keeper_person_note_set.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial surface, so a reader of these values never has to ask whether a
    schema loaded.

    All three moved: nothing in this shard derived a value from an owner
    module, which is what held tools back in the keeper and taskboard shards.
    [test_surface_tool_toml_parity] keeps the publication order; the
    descriptions and schemas it also pinned were copies of these values. *)

let schema_of_name = Tool_definition_embedded.schema

let surface_read = schema_of_name "keeper_surface_read"
let surface_post = schema_of_name "keeper_surface_post"
let person_note_set = schema_of_name "keeper_person_note_set"
