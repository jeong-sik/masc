module Types = Masc_domain

let sorted_unique values =
  List.sort_uniq String.compare values

let json_list values =
  `List (List.map (fun value -> `String value) values)

let () =
  let raw_all_tool_names =
    Masc_mcp.Config.raw_all_tool_schemas
    |> List.map (fun (schema : Types.tool_schema) -> schema.name)
    |> sorted_unique
  in
  let public_tool_names =
    Masc_mcp.Tool_catalog.public_mcp_tools
    |> sorted_unique
  in
  let contract_inventory =
    Test_mcp_tool_matrix_cases.all_known_tool_names
    |> sorted_unique
  in
  let body =
    `Assoc
      [
        ("raw_all_tool_names", json_list raw_all_tool_names);
        ("public_tool_names", json_list public_tool_names);
        ("contract_inventory", json_list contract_inventory);
      ]
  in
  Yojson.Safe.pretty_to_channel stdout body;
  output_char stdout '\n'
