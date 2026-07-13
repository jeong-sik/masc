(** Route evidence extraction for keeper tool-call I/O records. *)

let assoc_opt = function
  | `Assoc fields -> Some fields
  | _ -> None
;;


let route_candidate_has_fields json =
  match assoc_opt json with
  | None -> false
  | Some fields ->
    List.exists
      (fun (name, _) ->
         List.mem
           name
           [ "via"
           ; "sandbox_profile"
           ; "network_mode"
           ; "status"
           ])
      fields
;;

let route_candidate_of_output json =
  if route_candidate_has_fields json
  then Some json
  else (
    match Json_util.assoc_member_opt "result" json with
    | Some result when route_candidate_has_fields result -> Some result
    | _ ->
      (match Json_util.assoc_member_opt "detail" json with
       | Some detail when route_candidate_has_fields detail -> Some detail
       | _ -> None))
;;

let route_safe_command_string ~max_output_len:_ _command =
  (* Raw command strings do not preserve argv boundaries. Until the route
     evidence surface receives structured argv/Shell IR, fail closed instead
     of attempting shell parsing/redaction. *)
  "[REDACTED]"
;;

let route_safe_path_string _path = "[REDACTED]"

let route_text_for_evidence output_text =
  match Tool_output.decode_from_oas output_text with
  | Tool_output.Stored { preview; _ } -> preview
  | Tool_output.Inline value -> value
;;

let parse_tool_output_json_sanitized text =
  let text = Safe_ops.sanitize_text_utf8 text in
  try Ok (Yojson.Safe.from_string text) with
  | Yojson.Json_error msg -> Error msg
;;

let assoc_fields = function
  | `Assoc fields -> fields
  | _ -> []
;;

let descriptor_evidence_fields tool_name =
  match Keeper_tool_descriptor_resolution.descriptor_for_tool_name tool_name with
  | None -> []
  | Some descriptor -> Keeper_tool_descriptor.route_evidence_json descriptor |> assoc_fields
;;

let assoc_string_list_opt name json =
  match Json_util.assoc_member_opt name json with
  | None -> Some []
  | Some (`List items) ->
      let rec collect acc = function
        | [] -> Some (List.rev acc)
        | `String value :: rest -> collect (value :: acc) rest
        | _ -> None
      in
      collect [] items
  | Some _ -> None
;;

let typed_exec_command input =
  match Json_util.assoc_string_opt "executable" input with
  | Some executable ->
      (match assoc_string_list_opt "argv" input with
       | Some argv ->
           Some (String.concat " " (executable :: argv))
       | None -> None)
  | None -> None
;;

let route_evidence_json_of_tool_io ~max_output_len ~tool_name ~input ~output_text =
  let route_text = route_text_for_evidence output_text in
  let parsed_output =
    match parse_tool_output_json_sanitized route_text with
    | Ok json -> Some json
    | Error _ -> None
  in
  let route_json =
    match parsed_output with
    | Some json -> route_candidate_of_output json
    | None -> None
  in
  let command =
    match Json_util.assoc_string_opt "cmd" input with
    | Some cmd -> Some cmd
    | None -> (
        match typed_exec_command input with
        | Some _ as command -> command
        | None -> Json_util.assoc_string_opt "op" input)
  in
  let add_string name value fields =
    match value with
    | Some value -> (name, `String value) :: fields
    | None -> fields
  in
  let add_json name value fields =
    match value with
    | Some value -> (name, value) :: fields
    | None -> fields
  in
  let output_json = Option.value ~default:(`Assoc []) route_json in
  let descriptor_fields = descriptor_evidence_fields tool_name in
  if descriptor_fields = [] && Option.is_none route_json
  then None
  else (
    let dynamic_fields =
      []
      |> add_json
           "status"
           (Option.map
              (Observability_redact.preview_json_strings ~max_len:max_output_len)
              (Json_util.assoc_member_opt "status" output_json))
      |> add_string "network_mode" (Json_util.assoc_string_opt "network_mode" output_json)
      |> add_string "sandbox_profile" (Json_util.assoc_string_opt "sandbox_profile" output_json)
      |> add_string "via" (Json_util.assoc_string_opt "via" output_json)
      |> add_string "path" (Option.map route_safe_path_string (Json_util.assoc_string_opt "path" input))
      |> add_string "cwd" (Option.map route_safe_path_string (Json_util.assoc_string_opt "cwd" input))
      |> add_string "command" (Option.map (route_safe_command_string ~max_output_len) command)
      |> add_string "tool_name" (Some tool_name)
    in
    Some (`Assoc (descriptor_fields @ List.rev dynamic_fields)))
;;
