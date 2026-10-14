(** The six wiki tools, read from [config/tools/masc_wiki_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial wiki surface, so a reader of these values never has to ask
    whether a schema loaded.

    The whole decoded definition is published, not only the catalog schema:
    a file's [keeper_projection] table is the sentence a Keeper reads, and
    [Tool_schemas_wiki] carries it beside the schema so the descriptor
    never types its own.

    [masc_wiki_create]'s [source] enum is a literal in its TOML file.
    [Tool_wiki.wiki_source] owns that vocabulary, and the "wiki source
    enum" case in [test_enum_mirror_sync] compares the two.
    [test_wiki_tool_toml_parity] keeps the publication order and which
    tools declare a keeper_projection; the descriptions and schemas it also
    pinned were copies of these values. *)

let loaded_of_name name : Tool_definition_toml.loaded =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok loaded -> loaded
     | Error message -> failwith message)
;;

let list = loaded_of_name "masc_wiki_list"
let read = loaded_of_name "masc_wiki_read"
let create = loaded_of_name "masc_wiki_create"
let update = loaded_of_name "masc_wiki_update"
let search = loaded_of_name "masc_wiki_search"
let lint = loaded_of_name "masc_wiki_lint"
