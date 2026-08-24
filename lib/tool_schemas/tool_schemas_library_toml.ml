(** The four library tools, read from [config/tools/masc_library_*.toml] (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2).

    Each value is decoded once at module initialization. A missing file or a
    declaration that does not decode refuses the boot rather than advertising a
    partial library surface, so a reader of these values never has to ask
    whether a schema loaded.

    The source vocabulary is a literal in [Tool_schemas_library] rather than a
    variant, so nothing derives it from an owner and the whole list moved.
    [test_library_tool_toml_parity] pins all four against what the list
    published before the move. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let list = schema_of_name "masc_library_list"
let read = schema_of_name "masc_library_read"
let add = schema_of_name "masc_library_add"
let search = schema_of_name "masc_library_search"
