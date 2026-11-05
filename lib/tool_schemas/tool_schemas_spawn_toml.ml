(** The four spawn tools, read from [config/tools/keeper_spawn*.toml]
    (RFC prompts-and-tool-definitions-outside-ocaml §2.2).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial spawn
    surface, so a reader of these values never has to ask whether a schema
    loaded. *)

let schema_of_name = Tool_definition_embedded.schema

let start = schema_of_name "keeper_spawn"
let read = schema_of_name "keeper_spawn_read"
let wait = schema_of_name "keeper_spawn_wait"
let stop = schema_of_name "keeper_spawn_stop"
