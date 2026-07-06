(** Safe keeper tool execution marker extraction. *)

let sse_error_preview_max_chars = 300

let add_unique_marker marker markers =
  if List.mem marker markers then markers else marker :: markers
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
      match Json_util.get_string json "via" with
      | Some via -> add_via_marker via markers
      | None -> markers)
    else markers
  in
  let markers =
    match Json_util.get_string json "cmd" with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    match Json_util.get_string json "command" with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    match Json_util.get_string json "op_cmd" with
    | Some command -> add_command_markers command markers
    | None -> markers
  in
  let markers =
    if trusted_route_fields
    then (
      match Json_util.get_string json "action" with
      | Some action -> add_action_marker action markers
      | None -> markers)
    else markers
  in
  let markers =
    if trusted_route_fields
    then (
      match Json_util.get_string json "event" with
      | Some event -> add_event_marker event markers
      | None -> markers)
    else markers
  in
  markers
;;

type output_marker_parse_error =
  | Output_marker_json_decode_error of string

type tool_exec_result_marker_report =
  { markers : string list
  ; output_parse_error : output_marker_parse_error option
  }

let output_marker_parse_error_to_string = function
  | Output_marker_json_decode_error message ->
      Printf.sprintf "tool output marker JSON decode failed: %s" message

let output_marker_fields_result ~markers output =
  match Yojson.Safe.from_string output with
  | json ->
      let markers = add_json_marker_fields json markers in
      let markers =
        match json with
        | `Assoc fields -> (
            match List.assoc_opt "result" fields with
            | Some result -> add_json_marker_fields result markers
            | None -> markers)
        | _ -> markers
      in
      Ok markers
  | exception Yojson.Json_error message ->
      Error (Output_marker_json_decode_error message)

let tool_exec_result_marker_report ~(input : Yojson.Safe.t) ~(output : string)
    : tool_exec_result_marker_report =
  let markers = add_json_marker_fields ~trusted_route_fields:false input [] in
  match output_marker_fields_result ~markers output with
  | Ok markers -> { markers = List.rev markers; output_parse_error = None }
  | Error error ->
      { markers = List.rev markers; output_parse_error = Some error }

let tool_exec_result_markers ~(input : Yojson.Safe.t) ~(output : string) =
  (tool_exec_result_marker_report ~input ~output).markers
;;
