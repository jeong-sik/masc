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

let expected_structured_fusion_agent_build_files =
  List.sort
    String.compare
    [ "lib/fusion/fusion_judge.ml"; "lib/fusion/fusion_panel.ml" ]
;;

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

let fusion_agent_build_files () =
  ml_files_under "lib/fusion"
  |> List.filter (fun rel ->
    Ast_grep.count_calls ~module_path:rel ~callee:"Fusion_oas.build_agent" > 0)
  |> List.sort String.compare
;;

let expected_all_fusion_agent_build_files =
  expected_structured_fusion_agent_build_files
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

let test_librarian_runtime_does_not_preserve_unstructured_fallback () =
  let rel = "lib/keeper/keeper_librarian_runtime.ml" in
  check
    int
    "librarian runtime must not build unstructured fallback episodes"
    0
    (Ast_grep.count_value_bindings ~module_path:rel ~name:"unstructured_episode");
  check
    int
    "librarian runtime must not keep fallback preservation predicate"
    0
    (Ast_grep.count_value_bindings
       ~module_path:rel
       ~name:"should_preserve_unstructured_fallback");
  check
    int
    "librarian runtime must not construct unstructured fallback kind"
    0
    (Ast_grep.count_constructors ~module_path:rel ~constructor:"Unstructured_fallback");
  check
    (list string)
    "librarian runtime must not define extraction kind variants"
    []
    (Ast_grep.constructor_names_of_type ~module_path:rel ~type_name:"extraction_kind")
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

let test_fusion_agent_builds_request_structured_output () =
  test_agent_run_json_judges_request_structured_output
    expected_structured_fusion_agent_build_files
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

let test_dashboard_agent_run_json_judges_use_structured_judge_runtime () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " uses structured_judge runtime lane")
         1
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Runtime.runtime_id_for_structured_judge");
       check
         int
         (rel ^ " does not inherit fleet default runtime")
         0
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Runtime.get_default_runtime_id"))
    expected_structured_dashboard_agent_run_json_judges
;;

let test_dashboard_json_judges_do_not_use_lenient_json_recovery () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " must not call Llm_provider.Lenient_json.parse")
         0
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Llm_provider.Lenient_json.parse");
       check
         int
         (rel ^ " must not call Judge_json_recovery.extract_balanced_object")
         0
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Judge_json_recovery.extract_balanced_object"))
    expected_structured_dashboard_agent_run_json_judges
;;

let test_fusion_agent_builds_use_provider_config_transform () =
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
    expected_structured_fusion_agent_build_files
;;

let test_fusion_agent_builds_do_not_degrade_to_json_mode () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " must not downgrade provider-native schema to JsonMode")
         0
         (Ast_grep.count_constructors
            ~module_path:rel
            ~constructor:"Agent_sdk.Types.JsonMode"))
    expected_structured_fusion_agent_build_files
;;

let test_all_fusion_agent_build_files_are_classified () =
  check
    (list string)
    "all Fusion_oas.build_agent files"
    expected_all_fusion_agent_build_files
    (fusion_agent_build_files ())
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
      , "dispatch"
      , "Verifier_core.parse_grounded_verdict_from_json" )
    ; "lib/verifier_oas.ml", "dispatch", "Core.parse_verdict_from_json"
    ; ( "lib/workspace_metric_hooks.ml"
      , "dispatch"
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
    (fun (rel, binding_name, parser) ->
       check
         int
         (rel ^ " parses structured tool arguments in " ^ binding_name ^ " via " ^ parser)
         1
         (Ast_grep.count_calls_in_value_binding
            ~module_path:rel
            ~binding_name
            ~callee:parser))
    parser_expectations
;;

let test_structured_tool_agent_runs_request_provider_native_output () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " applies provider-native structured-output schema")
         1
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Keeper_structured_output_schema.apply_to_provider_config");
       check
         int
         (rel ^ " wires provider_config_transform")
         1
         (Ast_grep.count_calls_with_label
            ~module_path:rel
            ~callee:"Keeper_turn_driver_wrappers.run_named_with_masc_tools"
            ~label:"provider_config_transform"))
    expected_structured_tool_agent_runs
;;

let test_verifier_oas_uses_structured_judge_runtime () =
  let rel = "lib/verifier_oas.ml" in
  check
    int
    "verifier_oas uses structured_judge runtime lane"
    1
    (Ast_grep.count_calls
       ~module_path:rel
       ~callee:"Runtime.runtime_id_for_structured_judge");
  check
    int
    "verifier_oas does not inherit fleet default runtime for native schema"
    0
    (Ast_grep.count_calls
       ~module_path:rel
       ~callee:"Runtime.get_default_runtime_id")
;;

let test_verifier_oas_native_response_is_strict_json () =
  check
    int
    "verifier_oas native response must parse strict verdict JSON"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/verifier_oas.ml"
       ~binding_name:"verify"
       ~callee:"parse_verdict_from_structured_response_text");
  check
    int
    "verifier_oas native response must not call prose verdict parser"
    0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/verifier_oas.ml"
       ~binding_name:"verify"
       ~callee:"Core.parse_verdict")
;;

let test_adversarial_review_native_response_is_strict_json () =
  check
    int
    "adversarial review native response must parse strict grounded verdict JSON"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/keeper/keeper_adversarial_review.ml"
       ~binding_name:"run_grounded_review"
       ~callee:"parse_grounded_verdict_from_structured_response_text");
  check
    int
    "adversarial review must not keep prose JSON extraction helper"
    0
    (Ast_grep.count_value_bindings
       ~module_path:"lib/keeper/keeper_adversarial_review.ml"
       ~name:"parse_json_payload")
;;

let test_anti_rationalization_native_response_is_strict_json () =
  check
    int
    "anti-rationalization native response must parse strict verdict JSON"
    1
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/task/anti_rationalization.ml"
       ~binding_name:"review"
       ~callee:"parse_review_verdict_from_structured_response_text");
  check
    int
    "anti-rationalization native response must not call legacy prose verdict parser"
    0
    (Ast_grep.count_calls_in_value_binding
       ~module_path:"lib/task/anti_rationalization.ml"
       ~binding_name:"review"
       ~callee:"parse_verdict_typed")
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
            "dashboard Agent.run JSON judges use structured runtime lane"
            `Quick
            test_dashboard_agent_run_json_judges_use_structured_judge_runtime
        ; test_case
            "dashboard JSON judges do not use lenient JSON recovery"
            `Quick
            test_dashboard_json_judges_do_not_use_lenient_json_recovery
        ] )
    ; ( "fusion Agent builds"
      , [ test_case
            "Fusion agent build files are classified"
            `Quick
            test_all_fusion_agent_build_files_are_classified
        ; test_case
            "fusion Agent builds request structured output"
            `Quick
            test_fusion_agent_builds_request_structured_output
        ; test_case
            "fusion Agent builds use provider config transform"
            `Quick
            test_fusion_agent_builds_use_provider_config_transform
        ; test_case
            "fusion Agent builds do not degrade to JsonMode"
            `Quick
            test_fusion_agent_builds_do_not_degrade_to_json_mode
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
        ; test_case
            "tool-output Agent.run paths request provider-native schema"
            `Quick
            test_structured_tool_agent_runs_request_provider_native_output
        ; test_case
            "verifier_oas uses structured_judge runtime"
            `Quick
            test_verifier_oas_uses_structured_judge_runtime
        ; test_case
            "verifier_oas native response is strict JSON"
            `Quick
            test_verifier_oas_native_response_is_strict_json
        ; test_case
            "adversarial review native response is strict JSON"
            `Quick
            test_adversarial_review_native_response_is_strict_json
        ; test_case
            "anti-rationalization native response is strict JSON"
            `Quick
            test_anti_rationalization_native_response_is_strict_json
        ] )
    ; ( "model-label wrappers"
      , [ test_case
            "model-label wrappers can receive provider config transforms"
            `Quick
            test_model_label_wrappers_can_receive_provider_config_transform
        ] )
    ]
;;
