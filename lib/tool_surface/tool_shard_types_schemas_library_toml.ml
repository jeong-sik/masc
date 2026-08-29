(** The keeper_library_* declarations, read from the binary-embedded
    [config/tools/*.toml] tree (RFC prompts-and-tool-definitions-outside-ocaml
    §2.2, migration item 6).

    Decoded once at module initialization. A missing file or a declaration that
    does not decode refuses the boot rather than advertising a partial library
    surface, so a reader of these values never has to ask whether a schema
    loaded. [test_library_tool_toml_parity] pins both against what the OCaml
    literals published before they moved. *)

let schema_of_name name : Masc_domain.tool_schema =
  let rel = "tools/" ^ name ^ ".toml" in
  match Embedded_config.read rel with
  | None -> failwith (Printf.sprintf "embedded tool definition missing: %s" rel)
  | Some contents ->
    (match Tool_definition_toml.load ~name ~contents with
     | Ok { Tool_definition_toml.schema; _ } -> schema
     | Error message -> failwith message)
;;

let search = schema_of_name "keeper_library_search"
let read = schema_of_name "keeper_library_read"
