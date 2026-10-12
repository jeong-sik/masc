let label name =
  String.split_on_char '_' name
  |> List.map (fun segment ->
         if segment = "" then "" else String.capitalize_ascii segment)
  |> String.concat ""
