let loading_of_declaration ~path ~name ~contents =
  (Tool_declaration_table.declaration_of_file ~path ~name ~contents)
    .Tool_definition_toml.loading
;;

let loading_of_tool name =
  match Tool_declaration_table.find name with
  | Some loaded -> loaded.Tool_definition_toml.loading
  | None -> Tool_definition_toml.Always_loaded
;;
