(** Tool-neutral workflow rejection payload builder. *)

type scope_policy =
  | Observe_scope
  (* Legacy diagnostic value accepted for compatibility with older
     payloads. Runtime scope blocking is not driven by this field. *)
  | Block_scope

let scope_policy_to_string = function
  | Observe_scope -> "observe"
  | Block_scope -> "block_scope"
;;

let scope_policy_of_string value =
  match String.trim value with
  | "observe" -> Some Observe_scope
  | "block_scope" -> Some Block_scope
  | _ -> None
;;

let optional_string_field key value =
  match value with
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then [] else [ key, `String value ]
  | None -> []
;;

let payload_json
      ?rule_id
      ?tool_suggestion
      ?hint
      ?scope_policy
      ?(recoverable = false)
      ?(alternatives = [])
      ?(extra_fields = [])
      message
  =
  let scope_policy = Option.bind scope_policy scope_policy_of_string in
  let diagnosis =
    optional_string_field "rule_id" rule_id
    @ optional_string_field "tool_suggestion" tool_suggestion
    @
    match scope_policy with
    | Some scope_policy ->
      [ "scope_policy", `String (scope_policy_to_string scope_policy) ]
    | None -> []
  in
  let alternatives_field =
    if alternatives = []
    then []
    else
      [ ( "alternatives"
        , `List (List.map (fun name -> `String name) alternatives) )
      ]
  in
  let fields =
    [ "ok", `Bool false
    ; "error", `String message
    ; ( "failure_class"
      , `String (Tool_result.tool_failure_class_to_string Tool_result.Workflow_rejection) )
    ; "error_class", `String "deterministic"
    ; "recoverable", `Bool recoverable
    ]
    @ optional_string_field "hint" hint
    @ alternatives_field
    @ (if diagnosis = [] then [] else [ "diagnosis", `Assoc diagnosis ])
    @ extra_fields
  in
  Yojson.Safe.to_string (`Assoc fields)
;;
