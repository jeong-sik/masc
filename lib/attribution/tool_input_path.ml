let non_empty_string_member name input =
  match Yojson.Safe.Util.member name input with
  | `String raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let non_empty_string = function
  | `String raw ->
    let trimmed = String.trim raw in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let direct_path_keys =
  [ "path"
  ; "file_path"
  ; "target_path"
  ; "output_path"
  ; "destination_path"
  ]
;;

let nested_object_keys = [ "arguments"; "args"; "params"; "input" ]
;;

let list_path_keys =
  [ "paths"
  ; "file_paths"
  ; "files"
  ; "targets"
  ; "edits"
  ; "patches"
  ; "changes"
  ]
;;

let rec first_path_in_value = function
  | `String _ as json -> non_empty_string json
  | `Assoc _ as json -> tool_input_file_path json
  | _ -> None

and first_path_in_list = function
  | [] -> None
  | item :: rest ->
    (match first_path_in_value item with
     | Some _ as path -> path
     | None -> first_path_in_list rest)

and first_member_path names input =
  match names with
  | [] -> None
  | name :: rest ->
    (match non_empty_string_member name input with
     | Some _ as path -> path
     | None -> first_member_path rest input)

and first_nested_object_path names input =
  match names with
  | [] -> None
  | name :: rest ->
    (match Yojson.Safe.Util.member name input with
     | `Assoc _ as nested ->
       (match tool_input_file_path nested with
        | Some _ as path -> path
        | None -> first_nested_object_path rest input)
     | _ -> first_nested_object_path rest input)

and first_list_path names input =
  match names with
  | [] -> None
  | name :: rest ->
    (match Yojson.Safe.Util.member name input with
     | `List items ->
       (match first_path_in_list items with
        | Some _ as path -> path
        | None -> first_list_path rest input)
     | _ -> first_list_path rest input)

and tool_input_file_path input =
  match first_member_path direct_path_keys input with
  | Some _ as path -> path
  | None ->
    (match first_nested_object_path nested_object_keys input with
     | Some _ as path -> path
     | None -> first_list_path list_path_keys input)
;;
