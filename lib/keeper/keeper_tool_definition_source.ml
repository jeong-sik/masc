let resolve name =
  match Tool_help_registry.definition_source name with
  | Some _ as shipped -> shipped
  | None -> Keeper_tool_composition_catalog.skill_source_of_tool_name name

let annotate_row row =
  match row with
  | `Assoc fields -> (
    match Safe_ops.json_string_opt "tool" row with
    | None -> row
    | Some tool_name -> (
      match resolve tool_name with
      | None -> row
      | Some rel -> `Assoc (fields @ [ ("definition_source", `String rel) ])))
  | _ -> row
;;
