open Alcotest
open Masc

let schema_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let schema_property key schema =
  match schema_member "properties" schema with
  | Some (`Assoc properties) ->
    (match List.assoc_opt key properties with
     | Some value -> value
     | None -> failf "missing schema property %S" key)
  | _ -> failf "schema has no object properties while looking for %S" key
;;

let schema_items schema =
  match schema_member "items" schema with
  | Some value -> value
  | None -> fail "schema has no items member"
;;

let enum_strings schema =
  match schema_member "enum" schema with
  | Some (`List values) ->
    values
    |> List.filter_map (function
      | `String value -> Some value
      | _ -> None)
    |> List.sort String.compare
  | _ -> fail "schema has no enum member"
;;

let required_strings schema =
  match schema_member "required" schema with
  | Some (`List values) ->
    values
    |> List.filter_map (function
      | `String value -> Some value
      | _ -> None)
    |> List.sort String.compare
  | _ -> fail "schema has no required member"
;;

let allows_additional_properties schema =
  match schema_member "additionalProperties" schema with
  | Some (`Bool value) -> value
  | _ -> false
;;

let has_no_response_format provider_cfg =
  match provider_cfg.Llm_provider.Provider_config.response_format with
  | Agent_sdk.Types.Off -> true
  | Agent_sdk.Types.JsonMode | Agent_sdk.Types.JsonSchema _ -> false
;;
let test_operator_remote_tool_name_ssot_matches_remote_schemas () =
  let schema_names =
    Operator_tool.remote_schemas
    |> List.map (fun (schema : Masc_domain.tool_schema) -> schema.name)
    |> List.sort String.compare
  in
  check
    (list string)
    "operator remote schema names"
    (List.sort String.compare Tool_name.Operator_remote_name.all_strings)
    schema_names;
  check
    (list string)
    "operator remote exported names"
    (List.sort String.compare Tool_name.Operator_remote_name.all_strings)
    (List.sort String.compare Operator_tool.remote_tool_names);
  check bool "chat recovery cannot bypass operator profile" false
    (Tool_catalog.allow_direct_call "masc_operator_chat_recovery_resolve")
  ;
  check bool "Board quarantine recovery cannot bypass operator profile" false
    (Tool_catalog.allow_direct_call
       "masc_operator_board_attention_quarantine_requeue")
  ;
  check bool "task recovery cannot bypass operator profile" false
    (Tool_catalog.allow_direct_call "masc_operator_task_recovery_resolve")
;;

let test_fusion_judge_schema_uses_parser_wire_contract () =
  let schema = Keeper_structured_output_schema.fusion_judge_output_schema in
  check
    (list string)
    "fusion judge required fields"
    (List.sort
       String.compare
       [ Fusion_judge_parse.wire_field_decision
       ; Fusion_judge_parse.wire_field_resolved_answer
       ])
    (required_strings schema);
  let decision_kind_schema =
    schema
    |> schema_property Fusion_judge_parse.wire_field_decision
    |> schema_property Fusion_judge_parse.wire_field_decision_kind
  in
  check
    (list string)
    "fusion decision enum"
    (List.sort
       String.compare
       [ Fusion_judge_parse.wire_decision_answer
       ; Fusion_judge_parse.wire_decision_insufficient
       ; Fusion_judge_parse.wire_decision_recommend
       ])
    (enum_strings decision_kind_schema);
  let _consensus_text_schema =
    schema
    |> schema_property Fusion_judge_parse.wire_field_consensus
    |> schema_items
    |> schema_property Fusion_judge_parse.wire_field_consensus_text
  in
  let _position_stance_schema =
    schema
    |> schema_property Fusion_judge_parse.wire_field_contradictions
    |> schema_items
    |> schema_property Fusion_judge_parse.wire_field_positions
    |> schema_items
    |> schema_property Fusion_judge_parse.wire_field_stance
  in
  check bool "fusion schema exposes parser wire fields" true true
;;

let test_compaction_plan_schema_uses_codec_ssot () =
  let schema = Keeper_structured_output_schema.compaction_plan_output_schema in
  check
    (list string)
    "compaction plan required fields"
    [ Keeper_structured_output_schema.compaction_plan_field_decisions ]
    (required_strings schema);
  check bool "compaction plan is closed" false
    (allows_additional_properties schema);
  let decision_schema =
    schema
    |> schema_property Keeper_structured_output_schema.compaction_plan_field_decisions
    |> schema_items
  in
  check
    (list string)
    "compaction decision required fields"
    (List.sort
       String.compare
       [ Keeper_structured_output_schema.compaction_plan_field_unit_index
       ; Keeper_structured_output_schema.compaction_plan_field_action
       ; Keeper_structured_output_schema.compaction_plan_field_summary
       ])
    (required_strings decision_schema);
  check bool "compaction decision is closed" false
    (allows_additional_properties decision_schema);
  check
    (list string)
    "compaction action enum"
    (List.sort
       String.compare
       [ Keeper_structured_output_schema.compaction_plan_action_keep
       ; Keeper_structured_output_schema.compaction_plan_action_drop
       ; Keeper_structured_output_schema.compaction_plan_action_summarize
       ])
    (decision_schema
     |> schema_property Keeper_structured_output_schema.compaction_plan_field_action
     |> enum_strings)
;;

let test_consolidation_group_schema_keeps_claim_kind_optional () =
  let group_schema =
    Keeper_structured_output_schema.consolidation_plan_output_schema
    |> schema_property Keeper_memory_os_consolidation.wire_field_groups
    |> schema_items
  in
  check
    (list string)
    "consolidation group required fields"
    (List.sort
       String.compare
       [ Keeper_memory_os_consolidation.wire_field_member_indices
       ; Keeper_memory_os_consolidation.wire_field_consolidated_claim
       ; Keeper_memory_os_consolidation.wire_field_category
       ])
    (required_strings group_schema);
  let _claim_kind_schema =
    schema_property
      Keeper_memory_os_consolidation.wire_field_claim_kind
      group_schema
  in
  check bool "consolidation group remains closed" false
    (allows_additional_properties group_schema)
;;


(* The reviewer config must reach json_object-only providers. Counterfactual
   first: a native schema request on a Glm-kind config is rejected by the OAS
   contract — that rejection is exactly what left every task nonterminal
   fleet-wide on a Glm evaluator runtime (2026-07-21). The reviewer transform
   must therefore request no wire format at all and validate on Glm. *)
let glm_provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Glm
    ~model_id:"glm-5-turbo"
    ~base_url:"https://glm.invalid/api/paas/v4"
    ()
;;

let test_anti_rationalization_reviewer_config_reaches_glm () =
  let reviewer =
    Keeper_structured_output_schema.anti_rationalization_reviewer_provider_config
      (glm_provider_config ())
  in
  check bool "reviewer config carries no wire response format" true
    (has_no_response_format reviewer)
;;

let test_anti_rationalization_reviewer_config_clears_preset_response_format () =
  let preset =
    { (glm_provider_config ()) with
      response_format = Agent_sdk.Types.JsonMode
    }
  in
  let reviewer =
    Keeper_structured_output_schema.anti_rationalization_reviewer_provider_config preset
  in
  check
    bool
    "a pre-set response format on the incoming config is cleared, not inherited"
    true
    (has_no_response_format reviewer)
;;


let test_board_attention_batch_schema_uses_contract_ssot () =
  let schema =
    Keeper_structured_output_schema.board_attention_judgment_batch_output_schema
  in
  check
    (list string)
    "Board attention batch required fields"
    [ "verdicts" ]
    (required_strings schema);
  let item = schema |> schema_property "verdicts" |> schema_items in
  check
    (list string)
    "Board attention batch item required fields"
    [ "candidate_id"; "decision"; "rationale" ]
    (required_strings item);
  check
    (list string)
    "Board attention batch decision enum"
    (List.sort String.compare Keeper_board_attention_judgment.decision_tokens)
    (item |> schema_property "decision" |> enum_strings);
  check bool "Board attention batch item is closed" false
    (allows_additional_properties item);
  check bool "Board attention batch envelope is closed" false
    (allows_additional_properties schema)
;;


(* Regression guard for #25494. The deterministic subcall shape used to be
   hand-copied at each site; the second site's comment read "Mirror the
   librarian tuning". Thinking suppression is the load-bearing part —
   reasoning-capable providers otherwise spend the whole output budget on
   thinking and return empty visible text (consolidation logged 256
   consecutive Empty_response outcomes that way on 2026-07-20). These pin
   the fields so removing the suppression from the shared helper fails here
   instead of silently at one call site. *)

let base_provider_cfg () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.Anthropic
    ~model_id:"fake"
    ~base_url:"http://localhost"
    ()
;;

let test_deterministic_subcall_suppresses_thinking () =
  let cfg =
    Keeper_structured_output_schema.for_deterministic_subcall
      ~max_tokens:(Some 512)
      (base_provider_cfg ())
  in
  check
    (option bool)
    "enable_thinking must be explicitly false"
    (Some false)
    cfg.Llm_provider.Provider_config.enable_thinking;
  check
    (option bool)
    "preserve_thinking must be explicitly false"
    (Some false)
    cfg.Llm_provider.Provider_config.preserve_thinking;
  check
    (option bool)
    "clear_thinking must be explicitly true"
    (Some true)
    cfg.Llm_provider.Provider_config.clear_thinking;
  check
    bool
    "thinking_budget must be cleared"
    true
    (cfg.Llm_provider.Provider_config.thinking_budget = None)
;;

let test_deterministic_subcall_disables_tool_surface () =
  let cfg =
    Keeper_structured_output_schema.for_deterministic_subcall
      ~max_tokens:None
      (base_provider_cfg ())
  in
  check
    bool
    "tool_choice must be cleared"
    true
    (cfg.Llm_provider.Provider_config.tool_choice = None);
  check
    bool
    "parallel tool use must be disabled"
    true
    cfg.Llm_provider.Provider_config.disable_parallel_tool_use
;;

let test_deterministic_subcall_passes_max_tokens_through () =
  let cfg =
    Keeper_structured_output_schema.for_deterministic_subcall
      ~max_tokens:(Some 8192)
      (base_provider_cfg ())
  in
  check
    (option int)
    "max_tokens is the caller's, not the helper's"
    (Some 8192)
    cfg.Llm_provider.Provider_config.max_tokens
;;

let () =
  run
    "keeper-structured-output-schema"
    [ ( "dashboard schemas"
      , [ test_case
            "operator remote tool-name SSOT matches remote schemas"
            `Quick
            test_operator_remote_tool_name_ssot_matches_remote_schemas
        ] )
    ; ( "fusion schemas"
      , [ test_case
            "fusion judge schema uses parser wire contract"
            `Quick
            test_fusion_judge_schema_uses_parser_wire_contract
        ] )
    ; ( "compaction schemas"
      , [ test_case
            "compaction plan schema uses codec SSOT"
            `Quick
            test_compaction_plan_schema_uses_codec_ssot
        ; test_case
            "consolidation claim_kind remains optional"
            `Quick
            test_consolidation_group_schema_keeps_claim_kind_optional
        ] )
    ; ( "verdict schemas"
      , [ test_case
            "anti-rationalization reviewer config reaches a Glm provider"
            `Quick
            test_anti_rationalization_reviewer_config_reaches_glm
        ; test_case
            "anti-rationalization reviewer config clears a pre-set response format"
            `Quick
            test_anti_rationalization_reviewer_config_clears_preset_response_format
        ; test_case
            "Board attention batch schema uses contract SSOT"
            `Quick
            test_board_attention_batch_schema_uses_contract_ssot
        ] )
    ; ( "deterministic_subcall_shape"
      , [ test_case
            "thinking is suppressed"
            `Quick
            test_deterministic_subcall_suppresses_thinking
        ; test_case
            "tool surface is disabled"
            `Quick
            test_deterministic_subcall_disables_tool_surface
        ; test_case
            "max_tokens passes through"
            `Quick
            test_deterministic_subcall_passes_max_tokens_through
        ] )
    ]
;;
