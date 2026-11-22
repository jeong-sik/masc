(** Domain JSON schemas for keeper LLM sub-call parsers and exact-output flows. *)

let string_schema = `Assoc [ "type", `String "string" ]

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

let object_schema ~required properties =
  `Assoc
    [ "type", `String "object"
    ; "additionalProperties", `Bool false
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun key -> `String key) required)
    ]
;;

let librarian_working_contexts_schema =
  array_schema (object_schema
    ~required:["merge_contexts"; "sources"; "context"; "next_steps"]
    [ "merge_contexts", string_array_schema
    ; "sources", `Assoc
        [ "type", `String "array"; "items", string_schema; "minItems", `Int 1 ]
    ; "context", string_schema
    ; "next_steps", string_array_schema ])
;;

let librarian_working_context_output_schema =
  let fields =
    [ Keeper_librarian.wire_field_working_contexts, librarian_working_contexts_schema ]
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

let fusion_judge_output_schema = Fusion_judge_parse.output_schema

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
   [Agent_core.Structured.inspect_response_json] extracts JSON from the
   response's visible text, so parser behavior is independent of a provider
   response format. *)
let without_response_format (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with response_format = Agent_core.Types.Off }
;;

(* The anti-rationalization reviewer's verdict channel is the
   [report_review_verdict] tool call: exactly-once dispatch enforced in
   [Workspace_metric_hooks], args re-validated by the total parser behind
   [Task.Anti_rationalization.step_verdict_call]. A wire
   response format constrains only the final assistant text, which this
   surface never parses — while its capability branch rejected every
   json_object-only provider (Glm/DeepSeek/Kimi), so the gate
   never ran and every task stayed nonterminal fleet-wide (live incident
   2026-07-21). Converges with the fusion-judge / consolidation /
   board-attention / librarian surfaces above: no wire
   response format; the tool schema carries the verdict enum SSOT. Its
   requests join the verifier lane's admission queue. *)
let anti_rationalization_reviewer_provider_config provider_cfg =
  { (without_response_format provider_cfg) with
    Llm_provider.Provider_config.admission_class =
      Standalone_lane.admission_class Verifier
  }
;;

let for_deterministic_subcall ~max_tokens (provider_cfg : Llm_provider.Provider_config.t) =
  { provider_cfg with
    Llm_provider.Provider_config.max_tokens
  ; tool_choice = None
  ; disable_parallel_tool_use = true
  ; enable_thinking = Some false
  ; preserve_thinking = Some false
  }
;;
