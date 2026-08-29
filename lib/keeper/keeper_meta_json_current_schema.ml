(** Exact Keeper meta current-schema contract. *)

type validation_error = Invalid_current of string

let validation_error_detail (Invalid_current detail) = detail

let invalid_currentf format =
  Printf.ksprintf
    (fun detail ->
       Invalid_current
         (Printf.sprintf
            "invalid current keeper meta: %s; runtime reset required"
            detail))
    format
;;

type field =
  | Schema
  | Name
  | Instructions
  | Trace_id
  | Trace_history
  | Last_handoff_ts
  | Created_at
  | Updated_at
  | Total_turns
  | Total_input_tokens
  | Total_output_tokens
  | Total_tokens
  | Total_cost_usd
  | Last_turn_ts
  | Last_input_tokens
  | Last_output_tokens
  | Last_total_tokens
  | Last_latency_ms
  | Proactive_count_total
  | Last_proactive_ts
  | Proactive_visible_count_total
  | Last_visible_proactive_ts
  | Last_proactive_outcome
  | Last_proactive_reason
  | Last_proactive_preview
  | Message_scope_ack_id
  | Last_runtime_attempt
  | Paused
  | Latched_reason
  | Current_task_id
  | Keeper_id
  | Agent_core_env

let all_fields =
  [ Schema
  ; Name
  ; Instructions
  ; Trace_id
  ; Trace_history
  ; Last_handoff_ts
  ; Created_at
  ; Updated_at
  ; Total_turns
  ; Total_input_tokens
  ; Total_output_tokens
  ; Total_tokens
  ; Total_cost_usd
  ; Last_turn_ts
  ; Last_input_tokens
  ; Last_output_tokens
  ; Last_total_tokens
  ; Last_latency_ms
  ; Proactive_count_total
  ; Last_proactive_ts
  ; Proactive_visible_count_total
  ; Last_visible_proactive_ts
  ; Last_proactive_outcome
  ; Last_proactive_reason
  ; Last_proactive_preview
  ; Message_scope_ack_id
  ; Last_runtime_attempt
  ; Paused
  ; Latched_reason
  ; Current_task_id
  ; Keeper_id
  ; Agent_core_env
  ]

let field_name = function
  | Schema -> "schema"
  | Name -> "name"
  | Instructions -> "instructions"
  | Trace_id -> "trace_id"
  | Trace_history -> "trace_history"
  | Last_handoff_ts -> "last_handoff_ts"
  | Created_at -> "created_at"
  | Updated_at -> "updated_at"
  | Total_turns -> "total_turns"
  | Total_input_tokens -> "total_input_tokens"
  | Total_output_tokens -> "total_output_tokens"
  | Total_tokens -> "total_tokens"
  | Total_cost_usd -> "total_cost_usd"
  | Last_turn_ts -> "last_turn_ts"
  | Last_input_tokens -> "last_input_tokens"
  | Last_output_tokens -> "last_output_tokens"
  | Last_total_tokens -> "last_total_tokens"
  | Last_latency_ms -> "last_latency_ms"
  | Proactive_count_total -> "proactive_count_total"
  | Last_proactive_ts -> "last_proactive_ts"
  | Proactive_visible_count_total -> "proactive_visible_count_total"
  | Last_visible_proactive_ts -> "last_visible_proactive_ts"
  | Last_proactive_outcome -> "last_proactive_outcome"
  | Last_proactive_reason -> "last_proactive_reason"
  | Last_proactive_preview -> "last_proactive_preview"
  | Message_scope_ack_id -> "message_scope_ack_id"
  | Last_runtime_attempt -> "last_runtime_attempt"
  | Paused -> "paused"
  | Latched_reason -> "latched_reason"
  | Current_task_id -> "current_task_id"
  | Keeper_id -> "keeper_id"
  | Agent_core_env -> "agent_core_env"
;;

let current_field_names = List.map field_name all_fields

let object_of_field_values field_values =
  let supplied = List.map fst field_values in
  if supplied <> all_fields
  then
    invalid_arg
      "Keeper_meta_json_current_schema.object_of_field_values: field sequence \
       differs from the closed current schema"
  else
    `Assoc
      (List.map
         (fun (field, value) -> field_name field, value)
         field_values)
;;

let find_duplicate fields =
  let rec loop seen = function
    | [] -> None
    | (key, _) :: rest ->
      if List.mem key seen then Some key else loop (key :: seen) rest
  in
  loop [] fields
;;

let validate_current_object (json : Yojson.Safe.t) =
  match json with
  | `Assoc fields ->
    (match find_duplicate fields with
     | Some key ->
       Error
         (invalid_currentf "duplicate field %s" key)
     | None ->
       let present = List.map fst fields in
        let outside_current =
         List.filter (fun key -> not (List.mem key current_field_names)) present
       in
       let missing =
         List.filter (fun key -> not (List.mem key present)) current_field_names
       in
       if outside_current <> []
       then
         Error
           (invalid_currentf
              "fields outside the current schema: %s"
              (String.concat ", " outside_current))
       else if missing <> []
       then
         Error
           (invalid_currentf
              "missing required fields: %s"
              (String.concat ", " missing))
       else Ok fields)
  | other ->
    Error
      (invalid_currentf
         "expected an object, got %s"
         (Json_util.kind_name other))
;;
