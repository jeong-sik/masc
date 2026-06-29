open Alcotest

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

let expected_structured_agent_run_json_judges =
  List.sort
    String.compare
    [ "lib/dashboard/dashboard_governance_judge.ml"
    ; "lib/dashboard/dashboard_operator_judge.ml"
    ]
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

let test_agent_run_json_judges_request_structured_output () =
  List.iter
    (fun rel ->
       check
         int
         (rel ^ " applies structured-output schema")
         1
         (Ast_grep.count_calls
            ~module_path:rel
            ~callee:"Keeper_structured_output_schema.apply_to_provider_config"))
    expected_structured_agent_run_json_judges
;;

let test_agent_run_json_judges_use_provider_config_transform () =
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
    expected_structured_agent_run_json_judges
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
            test_agent_run_json_judges_request_structured_output
        ; test_case
            "dashboard Agent.run JSON judges use provider config transform"
            `Quick
            test_agent_run_json_judges_use_provider_config_transform
        ] )
    ]
;;
