open Alcotest
open Masc

let rec ml_files_under rel =
  let abs = Ast_grep.resolve_path rel in
  Sys.readdir abs
  |> Array.to_list
  |> List.sort String.compare
  |> List.concat_map (fun name ->
    let child_rel = Filename.concat rel name in
    let child_abs = Filename.concat abs name in
    if Sys.is_directory child_abs
    then ml_files_under child_rel
    else if Filename.check_suffix name ".ml"
    then [ child_rel ]
    else [])
;;

let direct_completion_files_under rel =
  ml_files_under rel
  |> List.filter (fun rel ->
    Ast_grep.count_calls ~module_path:rel ~callee:"Llm_provider.Complete.complete" > 0)
  |> List.sort String.compare
;;

let keeper_direct_completion_files () = direct_completion_files_under "lib/keeper"

let expected_structured_completion_files =
  List.sort
    String.compare
    [ "lib/keeper/keeper_librarian_runtime.ml"
    ; "lib/keeper/keeper_memory_llm_summary.ml"
    ; "lib/keeper/keeper_memory_os_consolidation_runtime.ml"
    ; "lib/keeper/keeper_vision_tool.ml"
    ]
;;

let expected_unstructured_completion_exemptions =
  List.sort
    String.compare
    [ (* Protocol probe: verifies plain OpenAI chat-completions compatibility. *)
      "lib/tool_local_runtime_verify.ml"
    ; (* Benchmark: measures arbitrary prompt latency/throughput. *)
      "lib/tool_local_runtime_bench.ml"
    ]
;;

let expected_structured_dashboard_agent_run_json_judges =
  List.sort
    String.compare
    [ "lib/dashboard/dashboard_governance_judge.ml"
    ; "lib/dashboard/dashboard_operator_judge.ml"
    ]
;;

let expected_structured_fusion_json_judges = [ "lib/fusion/fusion_judge.ml" ];;

let expected_structured_tool_agent_runs =
  List.sort
    String.compare
    [ "lib/keeper/keeper_adversarial_review.ml"
    ; "lib/verifier_oas.ml"
    ; "lib/workspace_metric_hooks.ml"
    ]
;;

let expected_masc_tool_agent_run_files =
  List.sort
    String.compare
    (expected_structured_dashboard_agent_run_json_judges
     @ expected_structured_tool_agent_runs)
;;

let masc_tool_agent_run_files_under rel =
  ml_files_under rel
  |> List.filter (fun rel ->
    Ast_grep.count_calls
      ~module_path:rel
      ~callee:"Keeper_turn_driver_wrappers.run_named_with_masc_tools"
    > 0)
  |> List.sort String.compare
;;

let expected_all_direct_completion_files =
  List.sort
    String.compare
    (expected_structured_completion_files @ expected_unstructured_completion_exemptions)
;;

let test_all_direct_completions_are_classified () =
  check
    (list string)
    "all direct completion files"
    expected_all_direct_completion_files
    (direct_completion_files_under "lib")
;;

let test_keeper_direct_completions_are_enumerated () =
  check
    (list string)
    "keeper direct completion files"
    expected_structured_completion_files
    (keeper_direct_completion_files ())
;;

let test_keeper_direct_completions_request_structured_output () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " applies structured-output schema")
         1
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Keeper_structured_output_schema.apply_to_provider_config"))
    expected_structured_completion_files
;;

let test_agent_run_json_judges_request_structured_output rels =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " applies structured-output schema")
         1
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Keeper_structured_output_schema.apply_to_provider_config"))
    rels
;;

let test_dashboard_agent_run_json_judges_request_structured_output () =
  test_agent_run_json_judges_request_structured_output
    expected_structured_dashboard_agent_run_json_judges
;;

let test_fusion_agent_run_json_judges_request_structured_output () =
  test_agent_run_json_judges_request_structured_output
    expected_structured_fusion_json_judges
;;

let test_dashboard_agent_run_json_judges_use_provider_config_transform () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " wires provider_config_transform")
         1
         (Ast_grep.count_calls_with_label
            ~module_path:rel
            ~callee:"Keeper_turn_driver_wrappers.run_named_with_masc_tools"
            ~label:"provider_config_transform"))
    expected_structured_dashboard_agent_run_json_judges
;;

let test_fusion_agent_run_json_judges_use_provider_config_transform () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " wires provider_config_transform")
         1
         (Ast_grep.count_calls_with_label
            ~module_path:rel
            ~callee:"Fusion_oas.build_agent"
            ~label:"provider_config_transform"))
    expected_structured_fusion_json_judges
;;

let test_all_masc_tool_agent_runs_are_classified () =
  check
    (list string)
    "all run_named_with_masc_tools files"
    expected_masc_tool_agent_run_files
    (masc_tool_agent_run_files_under "lib")
;;

let test_structured_tool_agent_runs_use_tool_schema_output () =
  let parser_expectations =
    [ ( "lib/keeper/keeper_adversarial_review.ml"
      , "Verifier_core.parse_grounded_verdict_from_json" )
    ; "lib/verifier_oas.ml", "Core.parse_verdict_from_json"
    ; ( "lib/workspace_metric_hooks.ml"
      , "Task.Anti_rationalization.parse_review_verdict_from_json" )
    ]
  in
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " wires MASC tool schemas into Agent.run")
         1
         (Ast_grep.count_calls_with_label
            ~module_path:rel
            ~callee:"Keeper_turn_driver_wrappers.run_named_with_masc_tools"
            ~label:"masc_tools"))
    expected_structured_tool_agent_runs;
  List.iter
    (fun (rel, parser) ->
       check
         int
         (rel ^ " parses structured tool arguments via " ^ parser)
         1
         (Ast_grep.count_calls ~module_path:rel ~callee:parser))
    parser_expectations
;;

let test_model_label_wrappers_can_receive_provider_config_transform () =
  let rel = "lib/keeper/keeper_turn_driver_wrappers.ml" in
  check
    int
    "model-label wrappers forward provider_config_transform to config_for_label"
    2
    (Ast_grep.count_calls_with_label
       ~module_path:rel
       ~callee:"config_for_label"
       ~label:"provider_config_transform");
  check
    int
    "config_for_label applies provider_config_transform"
    1
    (Ast_grep.count_calls ~module_path:rel ~callee:"transform")
;;

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

let () =
  run
    "keeper-structured-output-coverage"
    [ ( "all direct completion"
      , [ test_case
            "direct completion files are classified as structured or exempt"
            `Quick
            test_all_direct_completions_are_classified
        ] )
    ; ( "keeper direct completion"
      , [ test_case
            "lib/keeper direct completion files are enumerated"
            `Quick
            test_keeper_direct_completions_are_enumerated
        ; test_case
            "lib/keeper direct completions request structured output"
            `Quick
            test_keeper_direct_completions_request_structured_output
        ] )
    ; ( "dashboard json judges"
      , [ test_case
            "dashboard Agent.run JSON judges request structured output"
            `Quick
            test_dashboard_agent_run_json_judges_request_structured_output
        ; test_case
            "dashboard Agent.run JSON judges use provider config transform"
            `Quick
            test_dashboard_agent_run_json_judges_use_provider_config_transform
        ; test_case
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
    ; ( "fusion json judges"
      , [ test_case
            "fusion JSON judges request structured output"
            `Quick
            test_fusion_agent_run_json_judges_request_structured_output
        ; test_case
            "fusion JSON judges use provider config transform"
            `Quick
            test_fusion_agent_run_json_judges_use_provider_config_transform
        ; test_case
            "fusion judge schema uses parser wire contract"
            `Quick
            test_fusion_judge_schema_uses_parser_wire_contract
        ] )
    ; ( "structured tool Agent.run"
      , [ test_case
            "run_named_with_masc_tools files are classified"
            `Quick
            test_all_masc_tool_agent_runs_are_classified
        ; test_case
            "tool-output Agent.run paths parse structured tool arguments"
            `Quick
            test_structured_tool_agent_runs_use_tool_schema_output
        ] )
    ; ( "model-label wrappers"
      , [ test_case
            "model-label wrappers can receive provider config transforms"
            `Quick
            test_model_label_wrappers_can_receive_provider_config_transform
        ] )
    ]
;;
