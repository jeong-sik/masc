(** Domain JSON schemas for keeper LLM sub-call parsers and exact-output flows. *)

let string_schema = `Assoc [ "type", `String "string" ]

let string_array_schema =
  `Assoc [ "type", `String "array"; "items", string_schema ]
;;

(* A field the model must always answer, with null as the answer "none".
   Strict structured-output modes require every property to be required, so
   an optional value is spelled as a required nullable one. *)
let nullable_string_schema =
  `Assoc [ "type", `List [ `String "string"; `String "null" ] ]
;;

let array_schema item = `Assoc [ "type", `String "array"; "items", item ]

let enum_schema values =
  `Assoc
    [ "type", `String "string"
    ; "enum", `List (List.map (fun value -> `String value) values)
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

(* The claim carries where it was read: a Board post id, optionally a
   comment id, or null for the keeper's own transcript. Both are answered on
   every claim so strict schema modes accept the shape; the decoder treats
   null as absent. The field list is the same closed set the parser allows. *)
let librarian_claim_schema =
  let fields =
    [ Keeper_librarian.wire_field_claim, string_schema
    ; Keeper_librarian.wire_field_category, enum_schema category_tokens
    ; Keeper_memory_os_types.wire_field_board_post_id, nullable_string_schema
    ; Keeper_memory_os_types.wire_field_board_comment_id, nullable_string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let librarian_dropped_schema =
  let fields =
    [ Keeper_librarian.wire_field_memory_id, string_schema
    ; Keeper_librarian.wire_field_reason, string_schema
    ]
  in
  object_schema ~required:(List.map fst fields) fields
;;

let librarian_current_output_schema =
  let fields =
    [ Keeper_librarian.wire_field_retained_memory_ids, string_array_schema
    ; ( Keeper_librarian.wire_field_new_claims
      , `Assoc [ "type", `String "array"; "items", librarian_claim_schema ] )
    ; Keeper_librarian.wire_field_dropped, array_schema librarian_dropped_schema
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

(* Ask the provider for no wire response format. The call sites that use this
   state their output contract in the prompt and re-validate it in a total
   parser, so a native schema added no guarantee the parser did not already
   provide. What it did add was a capability branch:
   [validate_output_schema_request] rejects json_schema on every
   json_object-only endpoint (GLM/DeepSeek/Kimi), so those lanes fell back to
   the same prompt path anyway while logging one INFO line per keeper per tick.

   Two failure modes traced to that branch are closed by not taking it. The
   The json_object tier also 400s solely because a response_format was set at
   all.

   Note the parse path never read a provider-side structured field:
   [Agent_core.Structured.response_json_extractor] extracts JSON from the
   response's visible text, so parser behavior is independent of a provider
   response format. *)
let without_response_format (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with response_format = Agent_core.Types.Off }
;;

(* The anti-rationalization reviewer's verdict channel is the
   [report_review_verdict] tool call: exactly-once dispatch enforced in
   [Workspace_metric_hooks], args re-validated by the total parser
   [Task.Anti_rationalization.parse_review_verdict_from_json]. A wire
   response format constrains only the final assistant text, which this
   surface never parses — while its capability branch rejected every
   json_object-only provider (Glm/DeepSeek/Kimi), so the gate
   never ran and every task stayed nonterminal fleet-wide (live incident
   2026-07-21). Converges with the fusion-judge / consolidation /
   board-attention / librarian surfaces above: no wire
   response format; the tool schema carries the verdict enum SSOT. *)
let anti_rationalization_reviewer_provider_config = without_response_format

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
