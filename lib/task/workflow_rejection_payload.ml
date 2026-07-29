(** Tool-neutral workflow rejection payload builder. *)

let scope_policy_field value =
  match String.trim value with
  | "observe" -> "scope_policy", `String "observe"
  | removed_or_unknown ->
    invalid_arg
      (Printf.sprintf
         "Workflow_rejection_payload.payload: unsupported scope_policy %S; expected \
          \"observe\""
         removed_or_unknown)
;;

let optional_string_field key value =
  match value with
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then [] else [ key, `String value ]
  | None -> []
;;

let payload
      ?rule_id
      ?scope_policy
      ?(recoverable = false)
      ?(extra_fields = [])
      message
  =
  let diagnosis =
    optional_string_field "rule_id" rule_id
    @
    match scope_policy with
    | Some scope_policy -> [ scope_policy_field scope_policy ]
    | None -> []
  in
  let fields =
    [ "ok", `Bool false
    ; "error", `String message
    ; ( "failure_class"
      , `String
          (Tool_result.tool_failure_class_to_string
             Tool_result.Workflow_rejection) )
    ; "error_class", `String "deterministic"
    ; "recoverable", `Bool recoverable
    ]
    @ (if diagnosis = [] then [] else [ "diagnosis", `Assoc diagnosis ])
    @ extra_fields
  in
  `Assoc fields
;;

let payload_json
      ?rule_id
      ?scope_policy
      ?recoverable
      ?extra_fields
      message
  =
  payload
    ?rule_id
    ?scope_policy
    ?recoverable
    ?extra_fields
    message
  |> Yojson.Safe.to_string
;;
