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

let direct_agent_run_files_under rel =
  ml_files_under rel
  |> List.filter (fun rel ->
    Ast_grep.count_calls ~module_path:rel ~callee:"Agent_sdk.Agent.run" > 0)
  |> List.sort String.compare
;;

let direct_agent_run_files () =
  List.concat
    [ direct_agent_run_files_under "lib"; direct_agent_run_files_under "bin" ]
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
  List.sort String.compare [ "lib/fusion/fusion_judge.ml" ]
;;

let expected_freeform_fusion_agent_build_files =
  List.sort
    String.compare
    [ (* 패널 답변 계약은 free text다 (fusion_panel.ml 참조): 단일 문자열에 JSON
         envelope는 정보 이득 0에, provider가 schema를 무시하면 패널이 전멸하는
         실패 클래스만 추가했다 (2026-07-01 사고). *)
      "lib/fusion/fusion_panel.ml"
    ]
;;

let expected_structured_tool_agent_runs =
  List.sort
    String.compare
    [ "lib/keeper/keeper_adversarial_review.ml"
    ; "lib/verifier_oas.ml"
    ; "lib/workspace_metric_hooks.ml"
    ]
;;

let expected_freeform_masc_tool_agent_run_files =
  List.sort
    String.compare
    [ (* Eval harness: measures live tool-call attempts and arbitrary terminal text.
         Tool arguments remain structured through [completion_tools]. *)
      "bin/masc_completion_trust_eval.ml"
    ]
;;

let expected_masc_tool_agent_run_files =
  List.sort
    String.compare
    (expected_structured_dashboard_agent_run_json_judges
     @ expected_structured_tool_agent_runs
     @ expected_freeform_masc_tool_agent_run_files)
;;

let expected_freeform_direct_agent_run_files =
  List.sort
    String.compare
    [ (* Worker bridge: executes arbitrary OAS worker agents/tasks. The worker
         result text is the payload, so forcing a provider-native JSON envelope
         here would change the public worker contract. *)
      "lib/worker_oas.ml"
    ]
;;

let expected_all_direct_agent_run_files =
  expected_freeform_direct_agent_run_files
;;

let fusion_agent_build_files () =
  ml_files_under "lib/fusion"
  |> List.filter (fun rel ->
    Ast_grep.count_calls ~module_path:rel ~callee:"Fusion_oas.build_agent" > 0)
  |> List.sort String.compare
;;

let expected_all_fusion_agent_build_files =
  List.sort
    String.compare
    (expected_structured_fusion_agent_build_files
     @ expected_freeform_fusion_agent_build_files)
;;

let with_repo_oas_model_catalog f =
  let path = Ast_grep.resolve_path "oas-models.toml" in
  check bool "repo oas-models.toml present" true (Sys.file_exists path);
  match Llm_provider.Model_catalog.load_file path with
  | Error msg -> failf "repo oas-models.toml should load: %s" msg
  | Ok catalog ->
    Fun.protect
      ~finally:Llm_provider.Model_catalog.clear_global
      (fun () ->
         Llm_provider.Model_catalog.set_global catalog;
         f catalog)
;;

let fusion_toml_or_fail path =
  match Otoml.Parser.from_file_result path with
  | Ok toml -> toml
  | Error msg -> failf "fusion TOML parse failed: %s" msg
;;

let runtime_by_id_or_fail runtimes id =
  match List.find_opt (fun (runtime : Runtime.t) -> String.equal runtime.id id) runtimes with
  | Some runtime -> runtime
  | None -> failf "runtime id %s should resolve in repo runtime.toml" id
;;

let masc_tool_agent_run_files_under rel =
  ml_files_under rel
  |> List.filter (fun rel ->
    (Ast_grep.count_calls
       ~module_path:rel
       ~callee:"Keeper_turn_driver_wrappers.run_named_with_masc_tools"
     + Ast_grep.count_calls ~module_path:rel ~callee:"KTDW.run_named_with_masc_tools")
    > 0)
  |> List.sort String.compare
;;

let masc_tool_agent_run_files () =
  List.concat
    [ masc_tool_agent_run_files_under "lib"; masc_tool_agent_run_files_under "bin" ]
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

let test_all_direct_agent_runs_are_classified () =
  check
    (list string)
    "all direct Agent.run files"
    expected_all_direct_agent_run_files
    (direct_agent_run_files ())
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
         (rel ^ " must not fully qualify a JsonMode downgrade")
         0
         (Ast_grep.count_constructors
            ~module_path:rel
            ~constructor:"Agent_sdk.Types.JsonMode");
       check
         int
         (rel ^ " must not construct JsonMode through open or alias")
         0
         (Ast_grep.count_constructor_leaf_names ~module_path:rel ~name:"JsonMode"))
    expected_structured_fusion_agent_build_files
;;

(* 2-tier 계약: native schema 미선언 runtime도 prompt tier로 Ok — 계약 적용은
   total이다. seed 설정의 어떤 judge runtime도 빌드 단계에서 실패하지 않는다. *)
let test_repo_fusion_seed_judge_contract_is_total () =
  with_repo_oas_model_catalog @@ fun _catalog ->
  let path = Ast_grep.resolve_path "config/runtime.toml" in
  check bool "repo runtime.toml present" true (Sys.file_exists path);
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok
      ( runtimes
      , _default
      , _assignments
      , _librarian
      , _structured_judge
      , _cross_verifier
      , _media_failover , _lanes ) ->
    let runtime_cfg = fusion_toml_or_fail path in
    (match Fusion_config.of_toml runtime_cfg with
     | Error errs ->
       failf
         "repo fusion config should load: %s"
         (String.concat ", " (List.map Fusion_config.show_config_error errs))
     | Ok policy ->
       List.iter
         (fun validated_preset ->
            let preset = Fusion_policy.Validated_preset.preset validated_preset in
            let judge_runtime_ids =
              preset.Fusion_policy.judge
              :: List.map
                   (fun (judge : Fusion_policy.judge_spec) -> judge.jmodel)
                   preset.Fusion_policy.judges
            in
            List.iter
              (fun runtime_id ->
                 let runtime = runtime_by_id_or_fail runtimes runtime_id in
                 match
                   Fusion_judge.For_testing.apply_output_contract
                     runtime.provider_config
                 with
                 | Ok _ -> ()
                 | Error msg ->
                   failf
                     "fusion preset %s judge runtime %s: output contract must be total: %s"
                     preset.Fusion_policy.name
                     runtime_id
                     msg)
              judge_runtime_ids)
         policy.Fusion_policy.presets)
;;

let assert_panel_runtime_accepts_native_schema runtimes ~preset runtime_id =
  let runtime = runtime_by_id_or_fail runtimes runtime_id in
  match Fusion_panel.For_testing.apply_output_contract runtime.provider_config with
  | Ok _ -> ()
  | Error msg ->
    failf
      "fusion preset %s panel runtime %s must accept native schema: %s"
      preset
      runtime_id
      msg
;;

let test_repo_fusion_panel_presets_are_schema_capable () =
  with_repo_oas_model_catalog @@ fun _catalog ->
  let path = Ast_grep.resolve_path "config/runtime.toml" in
  match Runtime.load_list ~config_path:path with
  | Error msg -> failf "repo runtime.toml should load: %s" msg
  | Ok
      ( runtimes
      , _default
      , _assignments
      , _librarian
      , _structured_judge
      , _cross
      , _media , _lanes ) ->
    let runtime_cfg = fusion_toml_or_fail path in
    (match Fusion_config.of_toml runtime_cfg with
     | Error errs ->
       failf
         "repo fusion config should load: %s"
         (String.concat ", " (List.map Fusion_config.show_config_error errs))
     | Ok policy ->
       List.iter
         (fun validated_preset ->
            let preset = Fusion_policy.Validated_preset.preset validated_preset in
            List.iter
              (fun (group : Fusion_policy.panel_group) ->
                 List.iter
                   (assert_panel_runtime_accepts_native_schema
                      runtimes
                      ~preset:preset.Fusion_policy.name)
                   group.Fusion_policy.models)
              preset.Fusion_policy.panels)
         policy.Fusion_policy.presets)
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
    (masc_tool_agent_run_files ())
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

let test_verifier_oas_response_text_fallback_is_strict_json () =
  check
    int
    "verifier_oas must not call prose verdict parser for provider-native response text"
    0
    (Ast_grep.count_calls
       ~module_path:"lib/verifier_oas.ml"
       ~callee:"Core.parse_verdict")
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
    ; ( "all direct Agent.run"
      , [ test_case
            "direct Agent.run files are classified as structured or exempt"
            `Quick
            test_all_direct_agent_runs_are_classified
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
        ; test_case
            "repo Fusion seed judge output contract is total"
            `Quick
            test_repo_fusion_seed_judge_contract_is_total
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
            "verifier_oas response fallback is strict JSON"
            `Quick
            test_verifier_oas_response_text_fallback_is_strict_json
        ] )
    ; ( "model-label wrappers"
      , [ test_case
            "model-label wrappers can receive provider config transforms"
            `Quick
            test_model_label_wrappers_can_receive_provider_config_transform
        ] )
    ]
;;
