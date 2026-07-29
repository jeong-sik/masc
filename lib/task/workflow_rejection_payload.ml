(** Tool-neutral workflow rejection payload builder. *)

let optional_string_field key value =
  match value with
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then [] else [ key, `String value ]
  | None -> []
;;

let payload
      ?rule_id
      ?(recoverable = false)
      ?(extra_fields = [])
      message
  =
  let diagnosis = optional_string_field "rule_id" rule_id in
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
      ?recoverable
      ?extra_fields
      message
  =
  payload
    ?rule_id
    ?recoverable
    ?extra_fields
    message
  |> Yojson.Safe.to_string
;;
