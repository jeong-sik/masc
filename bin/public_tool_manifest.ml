let sorted_unique values = List.sort_uniq String.compare values
let json_list values = `List (List.map (fun value -> `String value) values)

let () =
  let public_tool_names = Masc_mcp.Tool_catalog.public_mcp_tools |> sorted_unique in
  `Assoc [ "public_tool_names", json_list public_tool_names ]
  |> Yojson.Safe.pretty_to_channel stdout;
  output_char stdout '\n'
;;
