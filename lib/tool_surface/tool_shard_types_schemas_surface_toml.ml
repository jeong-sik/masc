(** The surface tools, read from [config/tools/keeper_surface_*.toml].

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial surface, so a reader of these values never has to ask whether a
    schema loaded.

    Both moved: nothing in this shard derived a value from an owner
    module, which is what held tools back in the keeper and taskboard shards. *)

let schema_of_name = Tool_definition_embedded.schema

let surface_read = schema_of_name "keeper_surface_read"
let surface_post = schema_of_name "keeper_surface_post"
