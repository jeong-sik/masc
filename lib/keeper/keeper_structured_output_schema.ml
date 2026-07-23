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
    ; Keeper_librarian.wire_field_valid_for_days, nullable_integer_schema
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

(* Compaction plan codec. Only eligible source units cross the provider
   boundary. Each source-bound decision carries its own optional replacement
   summary, so application preserves source order and never relocates facts
   through one global prose block. Field names and action tokens are exported
   so schema, prompt, and parser share one wire SSOT. *)
let compaction_plan_field_decisions = "decisions"
let compaction_plan_field_unit_index = "unit_index"
let compaction_plan_field_action = "action"
let compaction_plan_field_summary = "summary"
let compaction_plan_action_keep = "keep"
let compaction_plan_action_drop = "drop"
let compaction_plan_action_summarize = "summarize"

let compaction_plan_output_schema =
  let decision_fields =
    [ compaction_plan_field_unit_index, integer_schema
    ; ( compaction_plan_field_action
      , enum_schema
          [ compaction_plan_action_keep
          ; compaction_plan_action_drop
          ; compaction_plan_action_summarize
          ] )
    ; compaction_plan_field_summary, nullable_string_schema
    ]
  in
  let decision_schema =
    object_schema ~required:(List.map fst decision_fields) decision_fields
  in
  let fields =
    [ compaction_plan_field_decisions, array_schema decision_schema ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let vision_analyze_output_schema =
  let fields = [ "text", string_schema ] in
  object_schema ~required:(List.map fst fields) fields
;;

let failure_judgment_output_schema =
  let fields =
    [ ( "decision"
      , enum_schema Keeper_failure_judgment_contract.decision_tokens )
    ; "guidance", nullable_string_schema
    ; "rationale", string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let board_attention_judgment_batch_output_schema =
  let item_fields =
    [ "candidate_id", string_schema
    ; ( "decision"
      , enum_schema Keeper_board_attention_judgment.decision_tokens )
    ; "rationale", string_schema
    ]
  in
  let fields =
    [ "verdicts"
    , array_schema (object_schema ~required:(List.map fst item_fields) item_fields)
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let hitl_context_summary_schema =
  let fields =
    [ "context_summary", string_schema
    ; "key_questions", string_array_schema
    ; ( "judgment"
      , enum_schema Keeper_approval_queue_rules_types.advisory_judgment_values )
    ; "rationale", string_schema
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

(* Ask the provider for no wire response format. The call sites that use this
   state their output contract in the prompt and re-validate it in a total
   parser, so a native schema added no guarantee the parser did not already
   provide. What it did add was a capability branch:
   [validate_output_schema_request] rejects json_schema on every
   json_object-only endpoint (GLM/DeepSeek/Kimi), so those lanes fell back to
   the same prompt path anyway while logging one INFO line per keeper per tick.

   Two failure modes traced to that branch are closed by not taking it. The
   librarian schema marks every claim field [required] with nullable types, so
   a schema-conforming provider emits ["claim_id": null] — which
   [Keeper_librarian.optional_string_field_strict] rejects, dropping the whole
   episode, while the prompt tells the model to omit the key instead. And the
   json_object tier only 400s because a response_format was set at all.

   Note the parse path never read a provider-side structured field:
   [Agent_sdk_response.structured_json_of_response] extracts JSON from the
   response's visible text, so native and prompt tiers converge on the same
   parser byte for byte. *)
let without_response_format (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    response_format = Agent_sdk.Types.Off
  ; output_schema = None
  }
;;

(* The anti-rationalization reviewer's verdict channel is the
   [report_review_verdict] tool call: exactly-once dispatch enforced in
   [Workspace_metric_hooks], args re-validated by the total parser
   [Task.Anti_rationalization.parse_review_verdict_from_json]. A wire
   response format constrains only the final assistant text, which this
   surface never parses — while its capability branch rejected every
   json_object-only provider (Glm/DeepSeek/Kimi) as
   [InvalidConfig "task.anti_rationalization.output_schema"], so the gate
   never ran and every task stayed nonterminal fleet-wide (live incident
   2026-07-21). Converges with the fusion-judge / failure-judge /
   consolidation / board-attention / librarian surfaces above: no wire
   response format; the tool schema carries the verdict enum SSOT. *)
let anti_rationalization_reviewer_provider_config = without_response_format

(* Capability-aware three-tier response-format selection for a request whose
   prompt already states the exact output shape (#25266). Tier 1: a provider
   that supports strict [json_schema] gets the schema enforced. Tier 2: a
   provider that supports only [json_object] JSON mode (GLM/DeepSeek/Kimi —
   the OpenAI-compat endpoints that reject json_schema) gets [JsonMode], which
   at least forces syntactically valid JSON; the caller's prompt carries the
   schema and the caller validates the parse, so the missing strict guarantee
   is covered. Tier 3: neither — prompt only. Without tier 2 every
   json_object-only provider is silently dropped from structured lanes,
   leaving the single json_schema-capable native endpoint (minimax) as a SPOF.
   Use ONLY where the prompt states the schema and the parse is validated
   downstream; [apply_to_provider_config] stays the strict default.

   CONTRACT (#25324): the OpenAI-compatible [json_object] response format
   requires the request messages to contain the literal token "json"
   (case-insensitive) or the endpoint returns HTTP 400. DeepSeek and Kimi
   enforce this; GLM is lenient. This function only sets [response_format] on
   [provider_cfg] and cannot see the messages, so any caller that reaches the
   JsonMode tier MUST include a "json" token in its prompt. The compaction
   summarizer does so in [Keeper_compaction_llm_summarizer.messages_for_plan]
   (locked by test_compaction_llm_summarizer). *)
let apply_schema_json_mode_or_prompt_tier ~log_label schema provider_cfg =
  let native_cfg = apply_to_provider_config schema provider_cfg in
  match Llm_provider.Provider_config.validate_output_schema_request native_cfg with
  | Ok () -> native_cfg
  | Error detail ->
    (match Llm_provider.Provider_config.capabilities_for_config_model provider_cfg with
     | Some caps when caps.Llm_provider.Capabilities.supports_response_format_json ->
       Log.Keeper.info
         "%s: json_object tier (native schema unavailable: %s)"
         log_label
         detail;
       { provider_cfg with
         response_format = Agent_sdk.Types.JsonMode
       ; output_schema = None
       }
     | _ ->
       Log.Keeper.info
         "%s: prompt tier (native schema and json mode unavailable: %s)"
         log_label
         detail;
       provider_cfg)
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

(* A provider is an eligible structured-lane candidate when it can enforce the
   schema (strict) OR at least honor JSON mode (#25266). The prompt-tier
   fallback exists but is not sufficient for eligibility: a provider with
   neither capability is filtered out, matching the pre-#25266 fail-closed
   behavior for that case. *)
let provider_config_accepts_schema_or_json_mode schema provider_cfg =
  match validate_provider_config schema provider_cfg with
  | Ok () -> true
  | Error _ ->
    (match Llm_provider.Provider_config.capabilities_for_config_model provider_cfg with
     | Some caps -> caps.Llm_provider.Capabilities.supports_response_format_json
     | None -> false)
;;

let for_deterministic_subcall ~max_tokens (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    Llm_provider.Provider_config.max_tokens
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  ; thinking_budget = None
  ; clear_thinking = Some true
  }
;;
