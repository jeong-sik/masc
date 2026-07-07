(** Provider-native JSON schemas for keeper LLM sub-call producers. *)

let string_schema = `Assoc [ "type", `String "string" ]
let number_schema = `Assoc [ "type", `String "number" ]
let integer_schema = `Assoc [ "type", `String "integer" ]
let boolean_schema = `Assoc [ "type", `String "boolean" ]
let nullable_string_schema = `Assoc [ "type", `List [ `String "string"; `String "null" ] ]
let nullable_integer_schema = `Assoc [ "type", `List [ `String "integer"; `String "null" ] ]

let string_array_schema =
  `Assoc [ "type", `String "array"; "items", string_schema ]
;;

let array_schema item = `Assoc [ "type", `String "array"; "items", item ]

let enum_schema values =
  `Assoc
    [ "type", `String "string"
    ; "enum", `List (List.map (fun value -> `String value) values)
    ]
;;

let nullable_enum_schema values =
  `Assoc
    [ "type", `List [ `String "string"; `String "null" ]
    ; "enum", `List ((`Null) :: List.map (fun value -> `String value) values)
    ]
;;

let object_schema ~required properties =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun key -> `String key) required)
    ]
;;

let nullable_object_schema ~required properties =
  `Assoc
    [ "type", `List [ `String "object"; `String "null" ]
    ; "additionalProperties", `Bool false
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun key -> `String key) required)
    ]
;;

let generic_object_schema =
  `Assoc [ "type", `String "object"; "additionalProperties", `Bool true ]
;;

let operator_action_tokens = Operator_approval.allowed_actions

let operator_severity_tokens = [ "warn"; "bad" ]

let operator_recommended_action_schema =
  let fields =
    [ "action_type", enum_schema operator_action_tokens
    ; "severity", enum_schema operator_severity_tokens
    ; "reason", string_schema
    ; "suggested_payload", generic_object_schema
    ]
  in
  nullable_object_schema ~required:(List.map fst fields) fields
;;

let operator_workspace_judgment_schema =
  let fields =
    [ "summary", string_schema
    ; "confidence", number_schema
    ; "evidence_refs", string_array_schema
    ; "disagreement_with_truth", boolean_schema
    ; "recommended_action", operator_recommended_action_schema
    ]
  in
  nullable_object_schema ~required:(List.map fst fields) fields
;;

let operator_session_judgment_schema =
  let fields =
    [ "session_id", string_schema
    ; "summary", string_schema
    ; "confidence", number_schema
    ; "evidence_refs", string_array_schema
    ; "disagreement_with_truth", boolean_schema
    ; "recommended_action", operator_recommended_action_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let operator_judge_output_schema =
  let fields =
    [ "workspace", operator_workspace_judgment_schema
    ; ( "sessions"
      , `Assoc
          [ "type", `String "array"; "items", operator_session_judgment_schema ] )
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let governance_kind_tokens = [ "case"; "agent_health"; "workspace_state" ]

let governance_resolved_tool_tokens = Tool_name.Operator_remote_name.all_strings

let governance_recommended_action_schema =
  let fields =
    [ "action_kind", string_schema
    ; "resolved_tool", nullable_enum_schema governance_resolved_tool_tokens
    ; "target_type", string_schema
    ; "target_id", nullable_string_schema
    ; "reason", string_schema
    ; "payload_preview", generic_object_schema
    ]
  in
  nullable_object_schema ~required:(List.map fst fields) fields
;;

let governance_guardrail_state_schema =
  let fields =
    [ "requires_human_gate", boolean_schema
    ; "pending_confirm_token", nullable_string_schema
    ; "ready_to_execute", boolean_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let governance_item_schema =
  let fields =
    [ "kind", enum_schema governance_kind_tokens
    ; "id", string_schema
    ; "summary", string_schema
    ; "confidence", number_schema
    ; "evidence_refs", string_array_schema
    ; "recommended_action", governance_recommended_action_schema
    ; "guardrail_state", governance_guardrail_state_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let governance_judge_output_schema =
  let fields =
    [ ( "items"
      , `Assoc [ "type", `String "array"; "items", governance_item_schema ] )
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let category_tokens =
  Keeper_memory_os_types.all_categories
  |> List.map Keeper_memory_os_types.category_to_string
;;

let librarian_claim_kind_tokens =
  Keeper_memory_os_types.librarian_claim_kinds
  |> List.map Keeper_memory_os_types.claim_kind_to_string
;;

let librarian_claim_schema =
  let fields =
    [ Keeper_librarian.wire_field_claim, string_schema
    ; Keeper_librarian.wire_field_category, enum_schema category_tokens
    ; Keeper_librarian.wire_field_source_turn, integer_schema
    ; Keeper_librarian.wire_field_source_tool_call_id, nullable_string_schema
    ; Keeper_librarian.wire_field_claim_id, nullable_string_schema
    ; Keeper_librarian.wire_field_claim_kind, nullable_enum_schema librarian_claim_kind_tokens
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let librarian_episode_output_schema =
  let fields =
    [ Keeper_librarian.wire_field_episode_summary, string_schema
    ; ( Keeper_librarian.wire_field_claims
      , `Assoc [ "type", `String "array"; "items", librarian_claim_schema ] )
    ; Keeper_librarian.wire_field_open_items, string_array_schema
    ; Keeper_librarian.wire_field_constraints, string_array_schema
    ; Keeper_librarian.wire_field_preserved_tool_refs, string_array_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let consolidation_group_schema =
  let fields =
    [ ( Keeper_memory_os_consolidation.wire_field_member_indices
      , `Assoc [ "type", `String "array"; "items", integer_schema ] )
    ; Keeper_memory_os_consolidation.wire_field_consolidated_claim, string_schema
    ; Keeper_memory_os_consolidation.wire_field_category, enum_schema category_tokens
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let consolidation_plan_output_schema =
  let fields =
    [ ( Keeper_memory_os_consolidation.wire_field_groups
      , `Assoc [ "type", `String "array"; "items", consolidation_group_schema ] )
    ; ( Keeper_memory_os_consolidation.wire_field_drop_indices
      , `Assoc [ "type", `String "array"; "items", integer_schema ] )
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let memory_bank_summary_output_schema =
  let fields = [ "summary", string_schema ] in
  object_schema ~required:(List.map fst fields) fields
;;

(* Compaction plan (RFC-0313-adjacent W2). The LLM classifies each working-set
   message by 0-based index into kept / summarized / dropped, and returns one
   [summary] prose block that stands in for the summarized indices. Index-based
   (not free-text rewrite) so the original messages are never fabricated — the
   consumer reconstructs the context by index, matching the
   [consolidation_plan] member_indices/drop_indices precedent. Field names are
   exported as constants so the parser shares this SSOT. *)
let compaction_plan_field_summary = "summary"
let compaction_plan_field_kept_indices = "kept_indices"
let compaction_plan_field_summarized_indices = "summarized_indices"
let compaction_plan_field_dropped_indices = "dropped_indices"

let compaction_plan_output_schema =
  let int_array = `Assoc [ "type", `String "array"; "items", integer_schema ] in
  let fields =
    [ compaction_plan_field_summary, string_schema
    ; compaction_plan_field_kept_indices, int_array
    ; compaction_plan_field_summarized_indices, int_array
    ; compaction_plan_field_dropped_indices, int_array
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let vision_analyze_output_schema =
  let fields = [ "text", string_schema ] in
  object_schema ~required:(List.map fst fields) fields
;;

let verification_evidence_ref_schema =
  let fields =
    [ "path", string_schema
    ; "line", nullable_integer_schema
    ; "quote", string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let verification_verdict_output_schema =
  let fields =
    [ "verdict", enum_schema Verifier_core.valid_verdict_strings
    ; "reason", nullable_string_schema
    ; "evidence", array_schema verification_evidence_ref_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let anti_rationalization_verdict_output_schema =
  let fields =
    [ "verdict", enum_schema Task.Anti_rationalization.valid_verdict_strings
    ; "reason", nullable_string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let hitl_context_summary_schema =
  let suggested_option_fields =
    [ "label", string_schema
    ; "rationale", string_schema
    ; ( "estimated_risk_delta"
      , nullable_enum_schema Keeper_approval_queue_rules_types.allowed_risk_level_values )
    ]
  in
  let suggested_option_schema =
    object_schema ~required:(List.map fst suggested_option_fields) suggested_option_fields
  in
  let fields =
    [ "context_summary", string_schema
    ; "key_questions", string_array_schema
    ; "suggested_options", array_schema suggested_option_schema
    ; "risk_rationale", nullable_string_schema
    ; "uncertainty", number_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let fusion_position_schema =
  let fields =
    [ Fusion_judge_parse.wire_field_model, string_schema
    ; Fusion_judge_parse.wire_field_stance, string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let fusion_claim_schema =
  let fields =
    [ Fusion_judge_parse.wire_field_consensus_text, string_schema
    ; Fusion_judge_parse.wire_field_supporting_models, string_array_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let fusion_contradiction_schema =
  let fields =
    [ Fusion_judge_parse.wire_field_topic, string_schema
    ; Fusion_judge_parse.wire_field_positions, array_schema fusion_position_schema
    ; Fusion_judge_parse.wire_field_evidence, string_array_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let fusion_coverage_schema =
  let fields =
    [ Fusion_judge_parse.wire_field_topic, string_schema
    ; Fusion_judge_parse.wire_field_addressed_by, string_array_schema
    ; Fusion_judge_parse.wire_field_missing, string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let fusion_insight_schema =
  let fields =
    [ Fusion_judge_parse.wire_field_consensus_text, string_schema
    ; Fusion_judge_parse.wire_field_model, string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let fusion_decision_schema =
  let fields =
    [ Fusion_judge_parse.wire_field_decision_kind
    , enum_schema
        [ Fusion_judge_parse.wire_decision_answer
        ; Fusion_judge_parse.wire_decision_recommend
        ; Fusion_judge_parse.wire_decision_insufficient
        ]
    ; Fusion_judge_parse.wire_field_answer, string_schema
    ; Fusion_judge_parse.wire_field_recommend_action, string_schema
    ; Fusion_judge_parse.wire_field_recommend_rationale, string_schema
    ; Fusion_judge_parse.wire_field_missing, string_array_schema
    ]
  in
  object_schema ~required:[ Fusion_judge_parse.wire_field_decision_kind ] fields
;;

let fusion_judge_output_schema =
  let fields =
    [ Fusion_judge_parse.wire_field_consensus, array_schema fusion_claim_schema
    ; ( Fusion_judge_parse.wire_field_contradictions
      , array_schema fusion_contradiction_schema )
    ; ( Fusion_judge_parse.wire_field_partial_coverage
      , array_schema fusion_coverage_schema )
    ; Fusion_judge_parse.wire_field_unique_insights, array_schema fusion_insight_schema
    ; Fusion_judge_parse.wire_field_blind_spots, string_array_schema
    ; Fusion_judge_parse.wire_field_resolved_answer, string_schema
    ; Fusion_judge_parse.wire_field_decision, fusion_decision_schema
    ]
  in
  object_schema
    ~required:
      [ Fusion_judge_parse.wire_field_resolved_answer
      ; Fusion_judge_parse.wire_field_decision
      ]
    fields
;;

let apply_to_provider_config schema (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    response_format = Agent_sdk.Types.JsonSchema schema
  ; output_schema = Some schema
  }
;;

let apply_hitl_summary_schema_to_config config =
  apply_to_provider_config hitl_context_summary_schema config
;;

let apply_schema_or_prompt_tier ~log_label schema provider_cfg =
  let native_cfg = apply_to_provider_config schema provider_cfg in
  match Llm_provider.Provider_config.validate_output_schema_request native_cfg with
  | Ok () -> native_cfg
  | Error detail ->
    Log.Keeper.info
      "%s: prompt tier (native schema unavailable: %s)"
      log_label
      detail;
    provider_cfg
;;

let validate_provider_config schema provider_cfg =
  provider_cfg
  |> apply_to_provider_config schema
  |> Llm_provider.Provider_config.validate_output_schema_request
;;

let provider_config_accepts_schema schema provider_cfg =
  match validate_provider_config schema provider_cfg with
  | Ok () -> true
  | Error _ -> false
;;
