let non_empty_string_member name input =
  match Yojson.Safe.Util.member name input with
  | `String raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let tool_input_file_path input =
  let rec first = function
    | [] -> None
    | name :: rest ->
      (match non_empty_string_member name input with
       | Some _ as path -> path
       | None -> first rest)
  in
  first [ "path"; "file_path" ]
;;
