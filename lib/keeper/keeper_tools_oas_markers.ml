(** Safe keeper tool execution marker extraction. *)

let sse_error_preview_max_chars = 300

let add_unique_marker marker markers =
  if List.mem marker markers then markers else marker :: markers
;;

let json_string_field_opt key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let strip_simple_quotes text =
  let len = String.length text in
  if len >= 2
  then (
    match text.[0], text.[len - 1] with
    | '\'', '\'' | '"', '"' -> String.sub text 1 (len - 2)
    | _ -> text)
  else text
;;

let command_words command =
  command
  |> String.split_on_char ' '
  |> List.filter_map (fun word ->
    match String.trim word with
    | "" -> None
    | word -> Some (strip_simple_quotes word |> String.lowercase_ascii))
;;

let add_command_markers command markers =
  match command_words command with
  | "git" :: "push" :: _ -> add_unique_marker "git push" markers
  | "gh" :: "pr" :: "create" :: _ -> add_unique_marker "gh pr create" markers
  | _ -> markers
;;

let add_action_marker action markers =
  match String.lowercase_ascii (String.trim action) with
  | "push" -> add_unique_marker "git push" markers
  | _ -> markers
;;

let add_event_marker event markers =
  match String.uppercase_ascii (String.trim event) with
  | "APPROVE" -> add_unique_marker "event=APPROVE" markers
  | _ -> markers
;;

let add_operation_marker operation markers =
  match String.lowercase_ascii (String.trim operation) with
  | "pr_create" -> add_unique_marker "gh pr create" markers
  | _ -> markers
;;

let allowed_via_marker = function
  | "brokered" | "docker" | "host" | "keeper" | "operator" | "system" | "taskmaster" ->
    true
  | _ -> false
;;

let add_via_marker via markers =
  let value = String.trim via |> String.lowercase_ascii in
  if allowed_via_marker value then add_unique_marker ("via=" ^ value) markers else markers
;;

let add_json_marker_fields ?(trusted_route_fields = true) json markers =
  let markers =
    if trusted_route_fields
    then (
      match json_string_field_opt "via" json with
      | Some via -> add_via_marker via markers
      | None -> markers)
    else markers
  in
  let markers =
    match json_string_field_opt "cmd" json with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    match json_string_field_opt "command" json with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    match json_string_field_opt "op_cmd" json with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    if trusted_route_fields
    then (
      match json_string_field_opt "action" json with
      | Some action -> add_action_marker action markers
      | None -> markers)
    else markers
  in
  let markers =
    if trusted_route_fields
    then (
      match json_string_field_opt "event" json with
      | Some event -> add_event_marker event markers
      | None -> markers)
    else markers
  in
  if trusted_route_fields
  then (
    match json_string_field_opt "operation" json with
    | Some operation -> add_operation_marker operation markers
    | None -> markers)
  else markers
;;

let tool_exec_result_markers ~(input : Yojson.Safe.t) ~(output : string) : string list =
  let markers = add_json_marker_fields ~trusted_route_fields:false input [] in
  let markers =
    try
      let json = Yojson.Safe.from_string output in
      let markers = add_json_marker_fields json markers in
      match json with
      | `Assoc fields ->
        (match List.assoc_opt "result" fields with
         | Some result -> add_json_marker_fields result markers
         | None -> markers)
      | _ -> markers
    with
    | Yojson.Json_error _ -> markers
  in
  List.rev markers
;;
