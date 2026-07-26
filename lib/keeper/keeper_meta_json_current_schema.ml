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

let current_field_names =
  [ "name"
  ; "agent_name"
  ; "persona"
  ; "instructions"
  ; "trace_id"
  ; "multimodal_policy"
  ; "trace_history"
  ; "generation"
  ; "last_handoff_ts"
  ; "created_at"
  ; "updated_at"
  ; "total_turns"
  ; "total_input_tokens"
  ; "total_output_tokens"
  ; "total_tokens"
  ; "total_cost_usd"
  ; "last_turn_ts"
  ; "last_input_tokens"
  ; "last_output_tokens"
  ; "last_total_tokens"
  ; "last_latency_ms"
  ; "compaction_count"
  ; "last_compaction_ts"
  ; "last_compaction_before_tokens"
  ; "last_compaction_after_tokens"
  ; "compaction_consecutive_failures"
  ; "proactive_count_total"
  ; "last_proactive_ts"
  ; "proactive_visible_count_total"
  ; "last_visible_proactive_ts"
  ; "last_proactive_outcome"
  ; "last_proactive_reason"
  ; "last_proactive_preview"
  ; "consecutive_noop_count"
  ; "last_compaction_check_ts"
  ; "last_compaction_decision"
  ; "active_goal_ids"
  ; "last_autonomous_action_at"
  ; "autonomous_action_count"
  ; "autonomous_turn_count"
  ; "autonomous_text_turn_count"
  ; "autonomous_tool_turn_count"
  ; "board_reactive_turn_count"
  ; "mention_reactive_turn_count"
  ; "noop_turn_count"
  ; "message_scope_ack_id"
  ; "last_blocker"
  ; "last_runtime_attempt"
  ; "paused"
  ; "latched_reason"
  ; "current_task_id"
  ; "keeper_id"
  ; "oas_env"
  ; "meta_version"
  ]

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
