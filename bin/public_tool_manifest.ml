let sorted_unique values =
  List.sort_uniq String.compare values

let json_list values =
  `List (List.map (fun value -> `String value) values)

let () =
  let public_tool_names =
    Masc.Config.visible_tool_schemas ()
    |> List.filter (fun (schema : Masc_domain.tool_schema) ->
      Tool_catalog.is_public_mcp schema.name)
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    |> sorted_unique
  in
  `Assoc [ ("public_tool_names", json_list public_tool_names) ]
  |> Yojson.Safe.pretty_to_channel stdout;
  output_char stdout '\n'
