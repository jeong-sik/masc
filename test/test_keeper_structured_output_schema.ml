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

let all_provider_native_schema_cases =
  [ "librarian_episode", Keeper_structured_output_schema.librarian_episode_output_schema
  ; "consolidation_plan", Keeper_structured_output_schema.consolidation_plan_output_schema
  ; "memory_bank_summary", Keeper_structured_output_schema.memory_bank_summary_output_schema
  ; "compaction_plan", Keeper_structured_output_schema.compaction_plan_output_schema
  ; "vision_analyze", Keeper_structured_output_schema.vision_analyze_output_schema
  ; "fusion_judge", Keeper_structured_output_schema.fusion_judge_output_schema
  ; "failure_judgment", Keeper_structured_output_schema.failure_judgment_output_schema
  ; ( "board_attention_judgment_batch"
    , Keeper_structured_output_schema.board_attention_judgment_batch_output_schema )
  ; ( "anti_rationalization_verdict"
    , Keeper_structured_output_schema.anti_rationalization_verdict_output_schema )
  ]
;;

let schema_capable_oas_provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"structured-output-ratchet"
    ~base_url:"https://structured-output.invalid/v1"
    ~model_capabilities_override:
      Llm_provider.Capabilities.openai_compat_chat_extended_capabilities
    ()
;;

let prompt_tier_oas_provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"prompt-tier-ratchet"
    ~base_url:"https://prompt-tier.invalid/v1"
    ~model_capabilities_override:
      { Llm_provider.Capabilities.openai_compat_chat_extended_capabilities with
        supports_structured_output = false
      }
    ()
;;

let test_all_schemas_apply_as_oas_native_json_schema () =
  let base = schema_capable_oas_provider_config () in
  List.iter
    (fun (label, schema) ->
       let configured =
         Keeper_structured_output_schema.apply_to_provider_config schema base
       in
       check
         bool
         (label ^ " response_format mirrors schema")
         true
         (match configured.Llm_provider.Provider_config.response_format with
          | Agent_sdk.Types.JsonSchema actual -> Yojson.Safe.equal schema actual
          | Agent_sdk.Types.JsonMode | Agent_sdk.Types.Off -> false);
       check
         bool
         (label ^ " output_schema mirrors schema")
         true
         (match configured.Llm_provider.Provider_config.output_schema with
          | Some actual -> Yojson.Safe.equal schema actual
          | None -> false);
       match Llm_provider.Provider_config.validate_output_schema_request configured with
       | Ok () -> ()
       | Error msg ->
         failf
           "%s should satisfy the OAS native structured-output contract: %s"
           label
           msg)
    all_provider_native_schema_cases
;;

let has_json_schema_response_format schema provider_cfg =
  match provider_cfg.Llm_provider.Provider_config.response_format with
  | Agent_sdk.Types.JsonSchema actual -> Yojson.Safe.equal schema actual
  | Agent_sdk.Types.JsonMode | Agent_sdk.Types.Off -> false
;;

let has_no_response_format provider_cfg =
  match provider_cfg.Llm_provider.Provider_config.response_format with
  | Agent_sdk.Types.Off ->
    Option.is_none provider_cfg.Llm_provider.Provider_config.output_schema
  | Agent_sdk.Types.JsonMode | Agent_sdk.Types.JsonSchema _ -> false
;;

(* A schema-capable provider gets no response format either: capability is not
   consulted. Without this the helper could silently regrow a native tier for
   the one provider class that accepts it, which is the split these call sites
   were changed to remove. *)
let test_without_response_format_clears_schema_capable_provider () =
  let base =
    Keeper_structured_output_schema.apply_to_provider_config
      Keeper_structured_output_schema.librarian_episode_output_schema
      (schema_capable_oas_provider_config ())
  in
  check bool "schema-capable provider starts with a native schema attached" true
    (has_json_schema_response_format
       Keeper_structured_output_schema.librarian_episode_output_schema
       base);
  check bool "helper clears it anyway" true
    (has_no_response_format (Keeper_structured_output_schema.without_response_format base))
;;

(* The point of the helper is that the request is byte-identical regardless of
   what the provider advertises, so a capability fact that turns out to be a lie
   (ollama.com cloud declared json_schema and ignored it — 2026-07-02 probe)
   cannot change the request that was sent. *)
let test_without_response_format_is_capability_independent () =
  let schema_capable =
    Keeper_structured_output_schema.without_response_format
      (schema_capable_oas_provider_config ())
  in
  let json_object_only =
    Keeper_structured_output_schema.without_response_format
      (prompt_tier_oas_provider_config ())
  in
  check bool "schema-capable provider asks for no format" true
    (has_no_response_format schema_capable);
  check bool "json_object-only provider asks for no format" true
    (has_no_response_format json_object_only);
  check bool "both configs pass output-schema validation" true
    (List.for_all
       (fun cfg ->
          match Llm_provider.Provider_config.validate_output_schema_request cfg with
          | Ok () -> true
          | Error _ -> false)
       [ schema_capable; json_object_only ])
;;

(* #25266: a json_object-only provider (structured_output=false,
   response_format_json=true — GLM/DeepSeek/Kimi's OpenAI-compat endpoints)
   must get JsonMode from the three-tier selector, not be dropped to the
   prompt tier. [prompt_tier_oas_provider_config] is exactly this shape:
   openai_compat_chat_extended has response_format_json=true, and it disables
   only structured_output. *)
let test_json_mode_tier_selects_json_mode_for_json_object_only () =
  let schema = Keeper_structured_output_schema.librarian_episode_output_schema in
  let base = prompt_tier_oas_provider_config () in
  let configured =
    Keeper_structured_output_schema.apply_schema_json_mode_or_prompt_tier
      ~log_label:"test json_mode"
      schema
      base
  in
  check bool "json_object-only provider gets JsonMode" true
    (match configured.Llm_provider.Provider_config.response_format with
     | Agent_sdk.Types.JsonMode -> true
     | Agent_sdk.Types.JsonSchema _ | Agent_sdk.Types.Off -> false);
  check (option bool) "JsonMode carries no output_schema" None
    (Option.map
       (Yojson.Safe.equal schema)
       configured.Llm_provider.Provider_config.output_schema)

let test_json_mode_tier_uses_native_schema_when_supported () =
  let schema = Keeper_structured_output_schema.librarian_episode_output_schema in
  let base = schema_capable_oas_provider_config () in
  let configured =
    Keeper_structured_output_schema.apply_schema_json_mode_or_prompt_tier
      ~log_label:"test native over json_mode"
      schema
      base
  in
  check bool "schema-capable provider still gets strict json_schema" true
    (has_json_schema_response_format schema configured)

let test_accepts_schema_or_json_mode_admits_json_object_only () =
  let schema = Keeper_structured_output_schema.librarian_episode_output_schema in
  (* json_schema-capable and json_object-only are both eligible; neither is not. *)
  check bool "json_schema provider is eligible" true
    (Keeper_structured_output_schema.provider_config_accepts_schema_or_json_mode
       schema (schema_capable_oas_provider_config ()));
  check bool "json_object-only provider is eligible" true
    (Keeper_structured_output_schema.provider_config_accepts_schema_or_json_mode
       schema (prompt_tier_oas_provider_config ()));
  let neither =
    Llm_provider.Provider_config.make
      ~kind:Llm_provider.Provider_config.OpenAI_compat
      ~model_id:"neither-ratchet"
      ~base_url:"https://neither.invalid/v1"
      ~model_capabilities_override:
        { Llm_provider.Capabilities.openai_compat_chat_extended_capabilities with
          supports_structured_output = false
        ; supports_response_format_json = false
        }
      ()
  in
  check bool "provider with neither capability is rejected" false
    (Keeper_structured_output_schema.provider_config_accepts_schema_or_json_mode
       schema neither)

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


let test_anti_rationalization_verdict_schema_uses_task_ssot () =
  let schema =
    Keeper_structured_output_schema.anti_rationalization_verdict_output_schema
  in
  check
    (list string)
    "anti-rationalization verdict required fields"
    [ "reason"; "verdict" ]
    (required_strings schema);
  check
    (list string)
    "anti-rationalization verdict enum"
    (List.sort String.compare Task.Anti_rationalization.valid_verdict_strings)
    (schema |> schema_property "verdict" |> enum_strings);
  check bool "anti-rationalization verdict is closed" false
    (allows_additional_properties schema)
;;

let test_failure_judgment_schema_uses_contract_ssot () =
  let schema = Keeper_structured_output_schema.failure_judgment_output_schema in
  check
    (list string)
    "failure judgment required fields"
    [ "decision"; "guidance"; "rationale" ]
    (required_strings schema);
  check
    (list string)
    "failure judgment decision enum"
    (List.sort String.compare Keeper_failure_judgment_contract.decision_tokens)
    (schema |> schema_property "decision" |> enum_strings);
  check bool "failure judgment verdict is closed" false
    (allows_additional_properties schema)
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
    [ ( "oas provider config"
      , [ test_case
            "all schemas apply as OAS native JSON schema requests"
            `Quick
            test_all_schemas_apply_as_oas_native_json_schema
        ; test_case
            "without_response_format clears a schema-capable provider too"
            `Quick
            test_without_response_format_clears_schema_capable_provider
        ; test_case
            "without_response_format is capability-independent"
            `Quick
            test_without_response_format_is_capability_independent
        ; test_case
            "json_mode tier selects JsonMode for json_object-only provider"
            `Quick
            test_json_mode_tier_selects_json_mode_for_json_object_only
        ; test_case
            "json_mode tier still uses strict schema when supported"
            `Quick
            test_json_mode_tier_uses_native_schema_when_supported
        ; test_case
            "accepts-schema-or-json-mode admits json_object-only, rejects neither"
            `Quick
            test_accepts_schema_or_json_mode_admits_json_object_only
        ] )
    ; ( "dashboard schemas"
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
        ] )
    ; ( "verdict schemas"
      , [ test_case
            "anti-rationalization verdict schema uses task SSOT"
            `Quick
            test_anti_rationalization_verdict_schema_uses_task_ssot
        ; test_case
            "failure judgment schema uses contract SSOT"
            `Quick
            test_failure_judgment_schema_uses_contract_ssot
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
