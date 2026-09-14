let repeat_of_tool name =
  match Tool_declaration_table.find name with
  | Some loaded -> loaded.Tool_definition_toml.repeat
  | None -> Tool_definition_toml.Same_input_reads
;;

let advances name =
  match repeat_of_tool name with
  | Tool_definition_toml.Same_input_advances -> true
  | Tool_definition_toml.Same_input_reads -> false
;;
