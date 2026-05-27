(** Keeper_tools_oas_workflow — Pure workflow rejection logic.

    Extracted from [Keeper_tools_oas] to separate pure computation
    from mutable state management.  No [failure_counts] mutation.

    @since P2 extraction *)

type workflow_rejection_scope_policy =
  | Observe_scope
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
  ; hint : string option
  ; scope_policy : workflow_rejection_scope_policy
  }

type workflow_rejection_block =
  { count : int
  ; rule_id : string option
  ; tool_suggestion : string option
  ; hint : string option
  ; blocked_at : float
  }

let json_assoc_field_opt = Keeper_tools_oas_json.json_assoc_field_opt
let json_assoc_string_opt = Keeper_tools_oas_json.json_assoc_string_opt
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
  match payload_from_json json with
  | Some _ as payload -> payload
  | None ->
    (match json_assoc_string_opt "error" json with
     | Some raw ->
       (try
          match Yojson.Safe.from_string raw with
          | `Assoc _ as nested -> payload_from_json nested
          | _ -> None
        with
        | Yojson.Json_error _ -> None)
     | None -> None)
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
  let fields =
    [ "ok", `Bool false
    ; "error", `String message
    ; "failure_class", `String "workflow_rejection"
    ; "error_class", `String (workflow_rejection_error_class_to_string error_class)
    ; "recoverable", `Bool (workflow_rejection_recoverability_to_bool recoverability)
    ]
    @ optional_string_field "hint" hint
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

let workflow_rejection_should_scope_block (info : workflow_rejection_info) =
  match info.scope_policy with
  | Block_scope -> true
  | Observe_scope -> false
;;

let workflow_rejection_family_key ~tool_name (info : workflow_rejection_info) =
  Printf.sprintf
    "%s:%s:%s:%s"
    (Option.value ~default:"unknown_task" info.task_id)
    tool_name
    (Option.value ~default:"unknown_rule" info.rule_id)
    (Option.value ~default:"unknown_tool" info.tool_suggestion)
;;

let workflow_rejection_recovery_instruction ~tool_name ~count (info : workflow_rejection_info) =
  match info.tool_suggestion with
  | Some next_tool when count >= 2 ->
    Printf.sprintf
      "Stop retrying %s variants for this workflow rejection. Call %s next and \
       follow the hint/alternatives in detail."
      tool_name
      next_tool
  | Some next_tool ->
    Printf.sprintf
      "Do not retry this %s call. Call %s next and follow the hint/alternatives \
       in detail."
      tool_name
      next_tool
  | None when count >= 2 ->
    Printf.sprintf
      "Stop retrying %s variants for this workflow rejection. Use a different \
       allowed workflow tool from the hint/alternatives in detail."
      tool_name
  | None ->
    Printf.sprintf
      "Do not retry this %s call. Use the hint/alternatives in detail."
      tool_name
;;

let workflow_rejection_recovery_fields ~tool_name ~count raw =
  match workflow_rejection_info_of_raw raw with
  | None -> []
  | Some info ->
    let optional_string key = function
      | Some value -> [ key, `String value ]
      | None -> []
    in
    let recovery =
      [ "count", `Int count
      ; "instruction", `String (workflow_rejection_recovery_instruction ~tool_name ~count info)
      ]
      @ optional_string "rule_id" info.rule_id
      @ optional_string "tool_suggestion" info.tool_suggestion
      @ optional_string "hint" info.hint
      @ [ ( "scope_policy"
          , `String (workflow_rejection_scope_policy_to_string info.scope_policy) )
        ]
    in
    [ "self_correction_required", `Bool true
    ; "do_not_retry_tool", `String tool_name
    ; "workflow_rejection_recovery", `Assoc recovery
    ]
    @ optional_string "required_next_tool" info.tool_suggestion
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
  if Option.is_some (json_nonempty_string_opt "pr_url" json)
     || json_has_nonempty_evidence_refs json
  then "has_evidence"
  else "missing_evidence"
;;

let workflow_scope_key_of_input ~tool_name input =
  let task_id_part json = json_nonempty_string_opt "task_id" json in
  match input with
  | `Assoc _ as json ->
    (match tool_name with
     | "masc_transition" ->
       (match json_nonempty_string_opt "action" json, task_id_part json with
        | None, _ | _, None -> None
        | Some action, Some task_id ->
          let correction_marker =
            if String.equal action "submit_for_verification"
            then ":" ^ workflow_submit_evidence_marker json
            else ""
          in
          Some
            (Printf.sprintf
               "%s:action=%s:task=%s%s"
               tool_name
               action
               task_id
               correction_marker))
     | "keeper_task_done"
     | "keeper_task_submit_for_verification" ->
       (match task_id_part json with
        | None -> None
        | Some task_id ->
          let correction_marker =
            if String.equal tool_name "keeper_task_submit_for_verification"
            then ":" ^ workflow_submit_evidence_marker json
            else ""
          in
          Some (Printf.sprintf "%s:task=%s%s" tool_name task_id correction_marker))
     | "keeper_task_claim" -> Some "keeper_task_claim"
     | _ -> None)
  | _ -> None
;;

let workflow_rejection_scope_block_fields ~tool_name block =
  let optional_string key = function
    | Some value -> [ key, `String value ]
    | None -> []
  in
  let recovery =
    [ "count", `Int (block.count + 1)
    ; "instruction"
      , `String
          (workflow_rejection_recovery_instruction
             ~tool_name
             ~count:(block.count + 1)
             ({ task_id = None
              ; rule_id = block.rule_id
              ; tool_suggestion = block.tool_suggestion
              ; hint = block.hint
              ; scope_policy = Block_scope
              } : workflow_rejection_info)
             )
    ]
    @ optional_string "rule_id" block.rule_id
    @ optional_string "tool_suggestion" block.tool_suggestion
    @ optional_string "hint" block.hint
    @ [ "scope_policy", `String (workflow_rejection_scope_policy_to_string Block_scope) ]
  in
  [ "self_correction_required", `Bool true
  ; "do_not_retry_tool", `String tool_name
  ; "workflow_rejection_recovery", `Assoc recovery
  ; "workflow_rejection_loop", `Bool true
  ; "retry_skipped", `Bool true
  ; "retry_skipped_reason", `String "deterministic_workflow_scope_blocked"
  ; ( "retry_skipped_explanation"
    , `String
        "previous workflow_rejection for this task/action scope requires a different next step" )
  ]
  @ optional_string "required_next_tool" block.tool_suggestion
;;
