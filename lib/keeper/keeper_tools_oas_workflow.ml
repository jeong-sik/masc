(** Keeper_tools_oas_workflow — Pure workflow rejection logic.

    Extracted from [Keeper_tools_oas] to separate pure computation
    from mutable state management.  No [failure_counts] mutation.

    @since P2 extraction *)

type workflow_rejection_info =
  { task_id : string option
  ; rule_id : string option
  ; tool_suggestion : string option
  ; hint : string option
  }

type workflow_rejection_block =
  { count : int
  ; rule_id : string option
  ; tool_suggestion : string option
  ; hint : string option
  }

let json_assoc_field_opt = Keeper_tools_oas_json.json_assoc_field_opt
let json_assoc_string_opt = Keeper_tools_oas_json.json_assoc_string_opt
let detail_json_opt = Keeper_tools_oas_json.detail_json_opt
let json_or_detail_string_opt = Keeper_tools_oas_json.json_or_detail_string_opt
let diagnosis_json_opt = Keeper_tools_oas_json.diagnosis_json_opt

let json_nonempty_string_opt key json =
  match json_assoc_field_opt key json with
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value "" then None else Some value
  | _ -> None
;;

let workflow_rejection_info_of_raw raw =
  try
    let json = Yojson.Safe.from_string raw in
    match json_or_detail_string_opt "failure_class" json with
    | Some "workflow_rejection" ->
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
      Some
        { task_id
        ; rule_id
        ; tool_suggestion
        ; hint = json_or_detail_string_opt "hint" json
        }
    | Some _
    | None ->
      None
  with
  | Yojson.Json_error _ -> None
;;

let workflow_rejection_family_key ~tool_name info =
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
              } : workflow_rejection_info)
             )
    ]
    @ optional_string "rule_id" block.rule_id
    @ optional_string "tool_suggestion" block.tool_suggestion
    @ optional_string "hint" block.hint
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
