(** Keeper meta current-schema key contract.

    The historical module path is retained to avoid namespace churn. It no
    longer scrubs or rewrites persisted JSON: old rows are rejected and require
    an explicit runtime reset. *)

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

let toml_only_field_names =
  [ "runtime_id"
  ; "sandbox_profile"
  ; "sandbox_image"
  ; "network_mode"
  ; "allowed_paths"
  ; "mention_targets"
  ; "proactive_enabled"
  ; "max_checkpoint_messages"
  ; "keep_recent_tool_results"
  ; "tool_heavy_msg_threshold"
  ; "tool_heavy_ratio_floor"
  ; "always_allow"
  ; "autoboot_enabled"
  ; "max_context_override"
  ; "telemetry_feedback_enabled"
  ; "telemetry_feedback_window_hours"
  ]

let retired_field_names =
  toml_only_field_names
  @ [ "auto_resume_after_sec"
    ; "goal"
    ; "compaction_mode"
    ; "initiative_enabled"
    ; "persona_profile_path"
    ; "tool_access"
    ; "tool_denylist"
    ; "policy_voice_enabled"
    ; "compaction_cooldown_sec"
    ; "compaction_profile"
    ; "compaction_ratio_gate"
    ; "compaction_message_gate"
    ; "compaction_token_gate"
    ; "keeper_name"
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
         (Printf.sprintf
            "keeper meta current schema has duplicate field %s; runtime reset required"
            key)
     | None ->
       let present = List.map fst fields in
       let retired =
         List.filter (fun key -> List.mem key retired_field_names) present
       in
       let unknown =
         List.filter
           (fun key ->
              not (List.mem key current_field_names)
              && not (List.mem key retired_field_names))
           present
       in
       let missing =
         List.filter (fun key -> not (List.mem key present)) current_field_names
       in
       if retired <> []
       then
         Error
           (Printf.sprintf
              "retired keeper meta fields are no longer supported: %s; runtime reset required"
              (String.concat ", " retired))
       else if unknown <> []
       then
         Error
           (Printf.sprintf
              "keeper meta current schema has unknown fields: %s; runtime reset required"
              (String.concat ", " unknown))
       else if missing <> []
       then
         Error
           (Printf.sprintf
              "keeper meta current schema is missing required fields: %s; runtime reset required"
              (String.concat ", " missing))
       else Ok fields)
  | other ->
    Error
      (Printf.sprintf
         "keeper meta current schema must be an object, got %s; runtime reset required"
         (Json_util.kind_name other))
;;
