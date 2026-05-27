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

let rec json_string_path_opt path json =
  match path with
  | [] -> None
  | [ name ] -> assoc_string_opt name json
  | name :: rest ->
    (match assoc_member_opt name json with
     | Some child -> json_string_path_opt rest child
     | None -> None)
;;

let rec json_bool_path_opt path json =
  match path with
  | [] -> None
  | [ name ] -> assoc_bool_opt name json
  | name :: rest ->
    (match assoc_member_opt name json with
     | Some child -> json_bool_path_opt rest child
     | None -> None)
;;

let first_some values = List.find_map Fun.id values

let contains_substring value needle =
  String_util.contains_substring
    (String.lowercase_ascii value)
    (String.lowercase_ascii needle)
;;

let has_prefix value prefix =
  let value_len = String.length value in
  let prefix_len = String.length prefix in
  value_len >= prefix_len && String.sub value 0 prefix_len = prefix
;;

let field_string_opt ~parsed_output ~route_json paths =
  let jsons = List.filter_map Fun.id [ parsed_output; route_json ] in
  List.find_map
    (fun path -> List.find_map (json_string_path_opt path) jsons)
    paths
;;

let field_bool_opt ~parsed_output ~route_json paths =
  let jsons = List.filter_map Fun.id [ parsed_output; route_json ] in
  List.find_map
    (fun path -> List.find_map (json_bool_path_opt path) jsons)
    paths
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

let assoc_fields = function
  | `Assoc fields -> fields
  | _ -> []
;;

let descriptor_evidence_fields tool_name =
  match Agent_tool_descriptor_resolution.descriptor_for_tool_name tool_name with
  | None -> []
  | Some descriptor -> Agent_tool_descriptor.route_evidence_json descriptor |> assoc_fields
;;

let descriptor_string_field name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None
;;

let approval_reason_from_text text =
  let marker = "approval_required" in
  let text = String.trim text in
  if has_prefix (String.lowercase_ascii text) marker
  then (
    match String.index_opt text ':' with
    | Some idx when idx + 1 < String.length text ->
      let reason = String.sub text (idx + 1) (String.length text - idx - 1) in
      let reason = String.trim reason in
      if reason = "" then Some marker else Some reason
    | _ -> Some marker)
  else None
;;

let decision_source_for_deny ~tool_name ~failure_class ~error ~reason ~rule_id ~shape_block =
  let values =
    [ Some tool_name; failure_class; error; reason; rule_id; shape_block ]
    |> List.filter_map Fun.id
  in
  let any_contains needle = List.exists (fun value -> contains_substring value needle) values in
  if any_contains "egress_blocked"
     || any_contains "network"
     || any_contains "sandbox"
  then "sandbox"
  else if any_contains "path"
          || any_contains "cwd_scope"
          || any_contains "allowed_paths"
  then "path_validator"
  else if any_contains "tool_execute"
          || Option.is_some shape_block
          || String.equal (String.lowercase_ascii tool_name) "execute"
          || String.equal (String.lowercase_ascii tool_name) "tool_execute"
  then "shell_gate"
  else "descriptor_policy"
;;

let policy_decision_fields ~tool_name ?success ~descriptor_fields ~parsed_output ~route_json ~route_text () =
  let failure_class =
    field_string_opt
      ~parsed_output
      ~route_json
      [ [ "failure_class" ]; [ "detail"; "failure_class" ] ]
  in
  let error =
    field_string_opt
      ~parsed_output
      ~route_json
      [ [ "error" ]; [ "detail"; "error" ] ]
  in
  let reason =
    field_string_opt
      ~parsed_output
      ~route_json
      [ [ "reason" ]; [ "detail"; "reason" ]; [ "retry_skipped_reason" ] ]
  in
  let rule_id =
    field_string_opt
      ~parsed_output
      ~route_json
      [ [ "diagnosis"; "rule_id" ]; [ "detail"; "diagnosis"; "rule_id" ] ]
  in
  let shape_block =
    field_string_opt
      ~parsed_output
      ~route_json
      [ [ "shape_block" ]; [ "detail"; "shape_block" ] ]
  in
  let ok_false =
    match
      field_bool_opt
        ~parsed_output
        ~route_json
        [ [ "ok" ]; [ "detail"; "ok" ] ]
    with
    | Some false -> true
    | _ -> false
  in
  let reason_for_deny =
    first_some [ error; rule_id; shape_block; reason; failure_class ]
  in
  let approval_reason =
    first_some
      [ approval_reason_from_text route_text
      ; (match error with
         | Some value when contains_substring value "approval_required" -> Some value
         | _ -> None)
      ; (match reason with
         | Some value when contains_substring value "approval_required" -> Some value
         | _ -> None)
      ; (match rule_id with
         | Some value when contains_substring value "approval_required" -> Some value
         | _ -> None)
      ]
  in
  let descriptor_present = descriptor_fields <> [] in
  let structured_mentions needle =
    [ failure_class; error; reason; rule_id; shape_block ]
    |> List.filter_map Fun.id
    |> List.exists (fun value -> contains_substring value needle)
  in
  let decision, source, decision_reason =
    match approval_reason with
    | Some approval_reason -> "ask", "approval_queue", approval_reason
    | None when structured_mentions "escalat" ->
      ( "escalate"
      , "descriptor_policy"
      , Option.value
          ~default:"escalation_required"
          (first_some [ reason_for_deny; Some "escalation_required" ]) )
    | None
      when (match failure_class with
            | Some value ->
              contains_substring value "policy_rejection"
              || contains_substring value "workflow_rejection"
            | None -> false)
           || (ok_false
               &&
               match error with
               | Some value ->
                 contains_substring value "tool_not_allowed"
                 || contains_substring value "not_allowed"
                 || contains_substring value "blocked"
               | None -> false) ->
      let source =
        decision_source_for_deny
          ~tool_name
          ~failure_class
          ~error
          ~reason
          ~rule_id
          ~shape_block
      in
      ( "deny"
      , source
      , Option.value
          ~default:
            (match success with
             | Some false -> "tool_call_denied"
             | _ -> "policy_rejection")
          reason_for_deny )
    | None ->
      ( "allow"
      , (if descriptor_present then "descriptor_policy" else "hook_observation")
      , (if descriptor_present
         then "descriptor_allows_tool"
         else "runtime_route_observed") )
  in
  [ "policy_decision", `String decision
  ; "decision_source", `String source
  ; "decision_reason", `String decision_reason
  ]
;;

let shell_ir_risk_fields ~descriptor_fields ~parsed_output ~route_json =
  match descriptor_string_field "executor" descriptor_fields with
  | Some "shell_ir" ->
    let risk_class =
      field_string_opt
        ~parsed_output
        ~route_json
        [ [ "classification"; "risk_class" ]
        ; [ "detail"; "classification"; "risk_class" ]
        ]
      |> Option.value ~default:"unknown"
    in
    [ "shell_ir_risk_class", `String risk_class ]
  | _ -> []
;;

let route_evidence_json_of_tool_io ~success ~max_output_len ~tool_name ~input ~output_text =
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
  let descriptor_fields = descriptor_evidence_fields tool_name in
  if descriptor_fields = [] && Option.is_none route_json
  then None
  else (
    let safe_input_string = route_safe_input_string ~max_output_len in
    let dynamic_fields =
      []
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
    let policy_decision_fields =
      policy_decision_fields
        ~tool_name
        ?success
        ~descriptor_fields
        ~parsed_output
        ~route_json
        ~route_text
        ()
    in
    let shell_ir_risk_fields =
      shell_ir_risk_fields ~descriptor_fields ~parsed_output ~route_json
    in
    Some
      (`Assoc
         (descriptor_fields
          @ policy_decision_fields
          @ shell_ir_risk_fields
          @ List.rev dynamic_fields)))
;;
