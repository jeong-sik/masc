(** The keeper_wiki_* declarations, read from the binary-embedded
    [config/tools/*.toml] tree.

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial wiki
    surface, so a reader of these values never has to ask whether a schema
    loaded. *)

let schema_of_name = Tool_definition_embedded.schema

let search = schema_of_name "keeper_wiki_search"
let read = schema_of_name "keeper_wiki_read"
