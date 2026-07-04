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
  ; "vision_analyze", Keeper_structured_output_schema.vision_analyze_output_schema
  ; "operator_judge", Keeper_structured_output_schema.operator_judge_output_schema
  ; "governance_judge", Keeper_structured_output_schema.governance_judge_output_schema
  ; "fusion_judge", Keeper_structured_output_schema.fusion_judge_output_schema
  ; "verification_verdict", Keeper_structured_output_schema.verification_verdict_output_schema
  ; ( "anti_rationalization_verdict"
    , Keeper_structured_output_schema.anti_rationalization_verdict_output_schema )
  ]
;;

let schema_capable_oas_provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"structured-output-ratchet"
    ~base_url:"https://structured-output.invalid/v1"
    ~supports_structured_output_override:true
    ~model_capabilities_override:
      Llm_provider.Capabilities.openai_compat_chat_extended_capabilities
    ()
;;

let prompt_tier_oas_provider_config () =
  Llm_provider.Provider_config.make
    ~kind:Llm_provider.Provider_config.OpenAI_compat
    ~model_id:"prompt-tier-ratchet"
    ~base_url:"https://prompt-tier.invalid/v1"
    ~supports_structured_output_override:false
    ~model_capabilities_override:
      Llm_provider.Capabilities.openai_compat_chat_extended_capabilities
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

let test_apply_schema_or_prompt_tier_uses_native_when_supported () =
  let schema = Keeper_structured_output_schema.librarian_episode_output_schema in
  let base = schema_capable_oas_provider_config () in
  let configured =
    Keeper_structured_output_schema.apply_schema_or_prompt_tier
      ~log_label:"test native"
      schema
      base
  in
  check bool "native schema is attached" true
    (has_json_schema_response_format schema configured);
  check (option bool) "output_schema mirrors native schema" (Some true)
    (Option.map
       (Yojson.Safe.equal schema)
       configured.Llm_provider.Provider_config.output_schema)
;;

let test_apply_schema_or_prompt_tier_keeps_prompt_config_when_native_rejected () =
  let schema = Keeper_structured_output_schema.librarian_episode_output_schema in
  let base = prompt_tier_oas_provider_config () in
  let native_cfg = Keeper_structured_output_schema.apply_to_provider_config schema base in
  (match Llm_provider.Provider_config.validate_output_schema_request native_cfg with
   | Ok () -> fail "prompt-tier provider unexpectedly accepted native schema"
   | Error _ -> ());
  let configured =
    Keeper_structured_output_schema.apply_schema_or_prompt_tier
      ~log_label:"test prompt"
      schema
      base
  in
  check bool "prompt tier has no native schema" false
    (has_json_schema_response_format schema configured);
  check (option bool) "prompt tier leaves output_schema empty" None
    (Option.map
       (Yojson.Safe.equal schema)
       configured.Llm_provider.Provider_config.output_schema);
  check
    bool
    "prompt-tier config still validates without native schema"
    true
    (match Llm_provider.Provider_config.validate_output_schema_request configured with
     | Ok () -> true
     | Error _ -> false)
;;

let operator_recommended_action_schema () =
  Keeper_structured_output_schema.operator_judge_output_schema
  |> schema_property "workspace"
  |> schema_property "recommended_action"
;;

let governance_recommended_action_schema () =
  Keeper_structured_output_schema.governance_judge_output_schema
  |> schema_property "items"
  |> schema_items
  |> schema_property "recommended_action"
;;

let test_operator_judge_schema_uses_action_approval_ssot () =
  let action_schema =
    operator_recommended_action_schema () |> schema_property "action_type"
  in
  check
    (list string)
    "operator action enum"
    (List.sort String.compare Operator_approval.allowed_actions)
    (enum_strings action_schema);
  check
    bool
    "goal completion decision is schema-admitted"
    true
    (List.mem
       Operator_action_constants.goal_completion_decision
       (enum_strings action_schema))
;;

let test_operator_judge_schema_allows_payload_objects () =
  let payload_schema =
    operator_recommended_action_schema () |> schema_property "suggested_payload"
  in
  check bool "suggested_payload admits object members" true
    (allows_additional_properties payload_schema)
;;

let test_governance_judge_schema_uses_resolved_tool_ssot () =
  let tool_schema =
    governance_recommended_action_schema () |> schema_property "resolved_tool"
  in
  check
    (list string)
    "governance resolved_tool enum"
    (List.sort String.compare Tool_name.Operator_remote_name.all_strings)
    (enum_strings tool_schema)
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
    (List.sort String.compare Operator_tool.remote_tool_names)
;;

let test_governance_judge_schema_allows_payload_objects () =
  let payload_schema =
    governance_recommended_action_schema () |> schema_property "payload_preview"
  in
  check bool "payload_preview admits object members" true
    (allows_additional_properties payload_schema)
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


let test_verification_verdict_schema_uses_core_ssot () =
  let schema = Keeper_structured_output_schema.verification_verdict_output_schema in
  check
    (list string)
    "verification verdict required fields"
    [ "evidence"; "reason"; "verdict" ]
    (required_strings schema);
  check
    (list string)
    "verification verdict enum"
    (List.sort String.compare Verifier_core.valid_verdict_strings)
    (schema |> schema_property "verdict" |> enum_strings);
  check bool "verification verdict is closed" false
    (allows_additional_properties schema);
  let evidence_schema =
    schema |> schema_property "evidence" |> schema_items
  in
  check
    (list string)
    "verification evidence required fields"
    [ "line"; "path"; "quote" ]
    (required_strings evidence_schema);
  check bool "verification evidence is closed" false
    (allows_additional_properties evidence_schema)
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

let () =
  run
    "keeper-structured-output-schema"
    [ ( "oas provider config"
      , [ test_case
            "all schemas apply as OAS native JSON schema requests"
            `Quick
            test_all_schemas_apply_as_oas_native_json_schema
        ; test_case
            "schema-or-prompt helper uses native schema when supported"
            `Quick
            test_apply_schema_or_prompt_tier_uses_native_when_supported
        ; test_case
            "schema-or-prompt helper keeps prompt tier when native rejected"
            `Quick
            test_apply_schema_or_prompt_tier_keeps_prompt_config_when_native_rejected
        ] )
    ; ( "dashboard schemas"
      , [ test_case
            "operator judge schema uses action approval SSOT"
            `Quick
            test_operator_judge_schema_uses_action_approval_ssot
        ; test_case
            "operator judge schema admits payload objects"
            `Quick
            test_operator_judge_schema_allows_payload_objects
        ; test_case
            "governance judge schema uses resolved-tool SSOT"
            `Quick
            test_governance_judge_schema_uses_resolved_tool_ssot
        ; test_case
            "operator remote tool-name SSOT matches remote schemas"
            `Quick
            test_operator_remote_tool_name_ssot_matches_remote_schemas
        ; test_case
            "governance judge schema admits payload objects"
            `Quick
            test_governance_judge_schema_allows_payload_objects
        ] )
    ; ( "fusion schemas"
      , [ test_case
            "fusion judge schema uses parser wire contract"
            `Quick
            test_fusion_judge_schema_uses_parser_wire_contract
        ] )
    ; ( "verdict schemas"
      , [ test_case
            "verification verdict schema uses core SSOT"
            `Quick
            test_verification_verdict_schema_uses_core_ssot
        ; test_case
            "anti-rationalization verdict schema uses task SSOT"
            `Quick
            test_anti_rationalization_verdict_schema_uses_task_ssot
        ] )
    ]
;;
