(** Keeper_tools_oas_workflow — Pure workflow rejection logic.

    Extracted from [Keeper_tools_oas] to separate pure computation
    from mutable state management.  No [failure_counts] mutation.

    @since P2 extraction *)

type workflow_rejection_scope_policy =
  | Observe_scope
  (* Legacy diagnostic value accepted for compatibility with older
     payloads. Runtime scope blocking is not driven by this field. *)
  | Block_scope

let workflow_rejection_scope_policy_to_string = function
  | Observe_scope -> "observe"
  | Block_scope -> "block_scope"
;;

let workflow_rejection_scope_policy_of_string value =
  match String.trim value with
  | "observe" -> Some Observe_scope
  | "block_scope" -> Some Block_scope
  | _ -> None
;;

type workflow_rejection_info =
  { task_id : string option
  ; rule_id : string option
  ; tool_suggestion : string option
  ; alternatives : string list
  ; hint : string option
  ; scope_policy : workflow_rejection_scope_policy
  }

let json_assoc_field_opt = Json_util.assoc_member_opt
let json_assoc_string_opt = Json_util.assoc_string_opt
let detail_json_opt = Keeper_tools_oas_json.detail_json_opt
let json_or_detail_string_opt = Keeper_tools_oas_json.json_or_detail_string_opt
let json_or_detail_bool_opt = Keeper_tools_oas_json.json_or_detail_bool_opt
let diagnosis_json_opt = Keeper_tools_oas_json.diagnosis_json_opt

let json_nonempty_string_opt key json =
  match json_assoc_field_opt key json with
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value "" then None else Some value
  | _ -> None
;;

let json_string_list_opt key json =
  match json_assoc_field_opt key json with
  | Some (`List values) ->
    let strings =
      List.filter_map
        (function
          | `String value ->
            let value = String.trim value in
            if String.equal value "" then None else Some value
          | _ -> None)
        values
    in
    if strings = [] then None else Some strings
  | _ -> None
;;

let json_or_detail_string_list_opt key json =
  match json_string_list_opt key json with
  | Some _ as value -> value
  | None ->
    (match detail_json_opt json with
     | Some detail -> json_string_list_opt key detail
     | None -> None)
;;

let workflow_rejection_info_of_json json =
  let diagnosis = diagnosis_json_opt json in
  let task_id = json_nonempty_string_opt "task_id" json in
  let rule_id =
    match diagnosis with
    | Some diagnosis -> json_assoc_string_opt "rule_id" diagnosis
    | None -> None
  in
  let tool_suggestion =
    match diagnosis with
    | Some diagnosis -> json_assoc_string_opt "tool_suggestion" diagnosis
    | None -> None
  in
  let scope_policy =
    match
      Option.bind diagnosis (fun diagnosis ->
        json_assoc_string_opt "scope_policy" diagnosis)
    with
    | Some value ->
      Option.value
        ~default:Observe_scope
        (workflow_rejection_scope_policy_of_string value)
    | None -> Observe_scope
  in
  { task_id
  ; rule_id
  ; tool_suggestion
  ; alternatives =
      (match json_or_detail_string_list_opt "alternatives" json with
       | Some alternatives -> alternatives
       | None -> [])
  ; hint = json_or_detail_string_opt "hint" json
  ; scope_policy
  }
;;

type workflow_rejection_error_class =
  | Workflow_error_deterministic
  | Workflow_error_transient
  | Workflow_error_other of string

let workflow_rejection_error_class_of_string value =
  match String.trim value with
  | "" -> None
  | "deterministic" -> Some Workflow_error_deterministic
  | "transient" -> Some Workflow_error_transient
  | other -> Some (Workflow_error_other other)
;;

let workflow_rejection_error_class_to_string = function
  | Workflow_error_deterministic -> "deterministic"
  | Workflow_error_transient -> "transient"
  | Workflow_error_other value -> value
;;

type workflow_rejection_recoverability =
  | Workflow_recoverable
  | Workflow_unrecoverable

let workflow_rejection_recoverability_of_bool = function
  | true -> Workflow_recoverable
  | false -> Workflow_unrecoverable
;;

let workflow_rejection_recoverability_to_bool = function
  | Workflow_recoverable -> true
  | Workflow_unrecoverable -> false
;;

type workflow_rejection_retry_policy =
  | Workflow_retry_observe
  | Workflow_retry_skip_deterministic

type workflow_rejection_payload =
  { info : workflow_rejection_info
  ; error_class : workflow_rejection_error_class option
  ; recoverability : workflow_rejection_recoverability option
  }

let workflow_rejection_payload_of_json json =
  let payload_from_json json =
  match json_or_detail_string_opt "failure_class" json with
  | Some "workflow_rejection" ->
    Some
      { info = workflow_rejection_info_of_json json
      ; error_class =
          Option.bind
            (json_or_detail_string_opt "error_class" json)
            workflow_rejection_error_class_of_string
      ; recoverability =
          Option.map
            workflow_rejection_recoverability_of_bool
            (json_or_detail_bool_opt "recoverable" json)
      }
  | Some _
  | None ->
    None
  in
  let nested_payload_of_json json =
    match json_assoc_string_opt "error" json with
    | Some raw ->
      (try
         match Yojson.Safe.from_string raw with
         | `Assoc _ as nested -> payload_from_json nested
         | _ -> None
       with
       | Yojson.Json_error _ -> None)
    | None -> None
  in
  let first_some left right =
    match left with
    | Some _ -> left
    | None -> right
  in
  let merge_info outer nested =
    { task_id = first_some nested.task_id outer.task_id
    ; rule_id = first_some nested.rule_id outer.rule_id
    ; tool_suggestion = first_some nested.tool_suggestion outer.tool_suggestion
    ; alternatives = if nested.alternatives = [] then outer.alternatives else nested.alternatives
    ; hint = first_some nested.hint outer.hint
    ; scope_policy =
        (match outer.scope_policy with
         | Block_scope -> Block_scope
         | Observe_scope -> nested.scope_policy)
    }
  in
  let merge_payload outer nested =
    { info = merge_info outer.info nested.info
    ; error_class = first_some nested.error_class outer.error_class
    ; recoverability = first_some nested.recoverability outer.recoverability
    }
  in
  match payload_from_json json with
  | Some payload ->
    (* Tool dispatch may wrap a typed workflow payload in the outer [error]
       string while retaining only [failure_class] at the outer level. The
       nested payload owns the recoverability bit; losing it turns a terminal
       rejection into a retry instruction. Merge both typed envelopes instead
       of scraping the human-readable error text. *)
    (match nested_payload_of_json json with
     | Some nested -> Some (merge_payload payload nested)
     | None -> Some payload)
  | None -> nested_payload_of_json json
;;

let workflow_rejection_retry_policy payload =
  match payload with
  | { error_class = Some Workflow_error_deterministic
    ; recoverability = Some Workflow_unrecoverable
    ; _
    } ->
    Workflow_retry_skip_deterministic
  | _ -> Workflow_retry_observe
;;

let workflow_rejection_should_skip_retry payload =
  match workflow_rejection_retry_policy payload with
  | Workflow_retry_skip_deterministic -> true
  | Workflow_retry_observe -> false
;;

let optional_string_field key value =
  match value with
  | Some value ->
    let value = String.trim value in
    if String.equal value "" then [] else [ key, `String value ]
  | None -> []
;;

let workflow_rejection_payload_json
      ?rule_id
      ?tool_suggestion
      ?hint
      ?scope_policy
      ?(alternatives = [])
      ?(extra_fields = [])
      ~error_class
      ~recoverability
      message
  =
  let diagnosis =
    optional_string_field "rule_id" rule_id
    @ optional_string_field "tool_suggestion" tool_suggestion
    @
    match scope_policy with
    | Some scope_policy ->
      [ "scope_policy", `String (workflow_rejection_scope_policy_to_string scope_policy) ]
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
    ; "failure_class", `String "workflow_rejection"
    ; "error_class", `String (workflow_rejection_error_class_to_string error_class)
    ; "recoverable", `Bool (workflow_rejection_recoverability_to_bool recoverability)
    ]
    @ optional_string_field "hint" hint
    @ alternatives_field
    @ (if diagnosis = [] then [] else [ "diagnosis", `Assoc diagnosis ])
    @ extra_fields
  in
  Yojson.Safe.to_string (`Assoc fields)
;;

let workflow_rejection_info_of_raw raw =
  try
    let json = Yojson.Safe.from_string raw in
    match workflow_rejection_payload_of_json json with
    | Some payload -> Some payload.info
    | None -> None
  with
  | Yojson.Json_error _ -> None
;;

let workflow_rejection_family_key ~tool_name (info : workflow_rejection_info) =
  let next_tool_key =
    match info.tool_suggestion with
    | Some tool -> tool
    | None ->
      (match
         List.find_opt
           (fun alternative -> not (String.equal alternative tool_name))
           info.alternatives
       with
       | Some tool -> tool
       | None -> "unknown_tool")
  in
  Printf.sprintf
    "%s:%s:%s:%s"
    (Option.value ~default:"unknown_task" info.task_id)
    tool_name
    (Option.value ~default:"unknown_rule" info.rule_id)
    next_tool_key
;;

let workflow_rejection_recovery_instruction ~tool_name ~count (info : workflow_rejection_info) =
  let next_tool =
    match info.tool_suggestion with
    | Some tool -> Some (`Required tool)
    | None ->
      Option.map
        (fun tool -> `Alternative tool)
        (List.find_opt
           (fun alternative -> not (String.equal alternative tool_name))
           info.alternatives)
  in
  match next_tool with
  | Some (`Required next_tool) when count >= 2 ->
    Printf.sprintf
      "Stop retrying %s variants for this workflow rejection. Call %s next and \
       follow the hint/alternatives in detail."
      tool_name
      next_tool
  | Some (`Required next_tool) ->
    Printf.sprintf
      "Use %s next for this workflow rejection and follow the hint/alternatives \
       in detail; %s is not the next valid action."
      next_tool
      tool_name
  | Some (`Alternative next_tool) when count >= 2 ->
    Printf.sprintf
      "Stop retrying %s variants for this workflow rejection. Use %s or another \
       listed alternative from detail."
      tool_name
      next_tool
  | Some (`Alternative next_tool) ->
    Printf.sprintf
      "Use %s or another listed alternative for this workflow rejection; %s is \
       not the next valid action."
      next_tool
      tool_name
  | None when count >= 2 ->
    Printf.sprintf
      "Stop retrying %s variants for this workflow rejection. Use a different \
       allowed workflow tool from the hint/alternatives in detail."
      tool_name
  | None ->
    Printf.sprintf
      "Revise your approach and retry this %s call. Use the hint/alternatives in detail."
      tool_name
;;

let workflow_rejection_recovery_fields ~tool_name ~count raw =
  let payload_opt =
    try
      workflow_rejection_payload_of_json (Yojson.Safe.from_string raw)
    with
    | Yojson.Json_error _ -> None
  in
  match payload_opt with
  | None -> []
  | Some payload ->
    let info = payload.info in
    let terminal = workflow_rejection_should_skip_retry payload in
    let optional_string key = function
      | Some value -> [ key, `String value ]
      | None -> []
    in
    let alternatives_field =
      match info.alternatives with
      | [] -> []
      | alternatives ->
        [ "alternatives", `List (List.map (fun name -> `String name) alternatives) ]
    in
    let next_tool_fields =
      match info.tool_suggestion with
      | Some next_tool -> [ "required_next_tool", `String next_tool ]
      | None ->
        (match
           List.find_opt
             (fun alternative -> not (String.equal alternative tool_name))
             info.alternatives
         with
         | Some next_tool -> [ "suggested_next_tool", `String next_tool ]
         | None -> [])
    in
    let instruction =
      if terminal && Option.is_none info.tool_suggestion && info.alternatives = []
      then
        Printf.sprintf
          "Do not retry this %s call: the workflow rejection is terminal for the \
           current task state. Inspect task history and choose an allowed next action."
          tool_name
      else workflow_rejection_recovery_instruction ~tool_name ~count info
    in
    let recovery =
      [ "count", `Int count
      ; "instruction", `String instruction
      ]
      @ optional_string "rule_id" info.rule_id
      @ optional_string "tool_suggestion" info.tool_suggestion
      @ optional_string "hint" info.hint
      @ alternatives_field
      @ [ ( "scope_policy"
          , `String (workflow_rejection_scope_policy_to_string info.scope_policy) )
        ]
    in
    [ "self_correction_required", `Bool (not terminal)
    ; "workflow_rejection_terminal", `Bool terminal
    ; "workflow_rejection_recovery", `Assoc recovery
    ]
    @ next_tool_fields
    @ if count >= 2 then [ "workflow_rejection_loop", `Bool true ] else []
;;

let json_has_nonempty_evidence_refs json =
  let nonempty_string = function
    | `String value -> not (String.equal (String.trim value) "")
    | _ -> false
  in
  match json_assoc_field_opt "handoff_context" json with
  | Some (`Assoc fields) ->
    (match List.assoc_opt "evidence_refs" fields with
     | Some (`List refs) -> List.exists nonempty_string refs
     | _ -> false)
  | _ -> false
;;

let workflow_submit_evidence_marker json =
  if Option.is_some (json_nonempty_string_opt "notes" json)
     || (match json_assoc_field_opt "evidence_refs" json with
         | Some (`List refs) ->
           List.exists
             (function
               | `String value -> not (String.equal (String.trim value) "")
               | _ -> false)
             refs
         | _ -> false)
     || json_has_nonempty_evidence_refs json
  then "has_evidence"
  else "missing_evidence"
;;
