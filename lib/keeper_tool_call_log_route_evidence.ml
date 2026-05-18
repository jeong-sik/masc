(** Route evidence extraction for keeper tool-call I/O records. *)

let assoc_opt = function
  | `Assoc fields -> Some fields
  | _ -> None
;;

let assoc_member_opt name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let assoc_string_opt name json =
  match assoc_member_opt name json with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None
;;

let assoc_bool_opt name json =
  match assoc_member_opt name json with
  | Some (`Bool value) -> Some value
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
           ; "git_creds_enabled"
           ; "network_mode"
           ; "status"
           ; "effective_sandbox_image"
           ])
      fields
;;

let route_candidate_of_output json =
  if route_candidate_has_fields json
  then Some json
  else (
    match assoc_member_opt "result" json with
    | Some result when route_candidate_has_fields result -> Some result
    | _ ->
      (match assoc_member_opt "detail" json with
       | Some detail when route_candidate_has_fields detail -> Some detail
       | _ -> None))
;;

let find_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0
  then Some 0
  else (
    let rec loop idx =
      if idx + needle_len > haystack_len
      then None
      else if String.sub haystack idx needle_len = needle
      then Some idx
      else loop (idx + 1)
    in
    loop 0)
;;

let github_pull_url_of_text text =
  match find_substring ~needle:"https://github.com/" text with
  | None -> None
  | Some start ->
    let len = String.length text in
    let rec stop idx =
      if idx >= len
      then idx
      else (
        match text.[idx] with
        | ' ' | '\n' | '\r' | '\t' | '"' | '\'' | ')' | ']' -> idx
        | _ -> stop (idx + 1))
    in
    let finish = stop start in
    let url = String.sub text start (finish - start) in
    if find_substring ~needle:"/pull/" url |> Option.is_some then Some url else None
;;

let route_output_url output_json output_text =
  match assoc_string_opt "url" output_json with
  | Some url when find_substring ~needle:"/pull/" url |> Option.is_some -> Some url
  | _ -> github_pull_url_of_text output_text
;;

let route_safe_input_string ~max_output_len value =
  Option.map (Observability_redact.redact_preview ~max_len:max_output_len) value
;;

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
    match assoc_string_opt "cmd" input with
    | Some cmd -> Some cmd
    | None -> assoc_string_opt "op" input
  in
  let add_string name value fields =
    match value with
    | Some value -> (name, `String value) :: fields
    | None -> fields
  in
  let add_bool name value fields =
    match value with
    | Some value -> (name, `Bool value) :: fields
    | None -> fields
  in
  let add_json name value fields =
    match value with
    | Some value -> (name, value) :: fields
    | None -> fields
  in
  let output_json = Option.value ~default:(`Assoc []) route_json in
  let pr_url =
    match parsed_output with
    | Some json -> route_output_url json route_text
    | None -> github_pull_url_of_text route_text
  in
  if Option.is_none route_json && Option.is_none pr_url
  then None
  else (
    let safe_input_string = route_safe_input_string ~max_output_len in
    let fields =
      []
      |> add_string "pr_url" pr_url
      |> add_json
           "status"
           (Option.map
              (Observability_redact.preview_json_strings ~max_len:max_output_len)
              (assoc_member_opt "status" output_json))
      |> add_string
           "effective_sandbox_image"
           (assoc_string_opt "effective_sandbox_image" output_json)
      |> add_string "network_mode" (assoc_string_opt "network_mode" output_json)
      |> add_bool "git_creds_enabled" (assoc_bool_opt "git_creds_enabled" output_json)
      |> add_string "sandbox_profile" (assoc_string_opt "sandbox_profile" output_json)
      |> add_string "via" (assoc_string_opt "via" output_json)
      |> add_string "path" (safe_input_string (assoc_string_opt "path" input))
      |> add_string "cwd" (safe_input_string (assoc_string_opt "cwd" input))
      |> add_string "command" (safe_input_string command)
      |> add_string "tool_name" (Some tool_name)
    in
    match fields with
    | [ "tool_name", _ ] -> None
    | _ -> Some (`Assoc (List.rev fields)))
;;
