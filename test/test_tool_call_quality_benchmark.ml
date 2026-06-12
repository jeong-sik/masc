open Alcotest
open Masc

let fixture_cases repo_root =
  Tool_call_quality_benchmark.default_case_set_path ~repo_root

let fixture_runs repo_root =
  Filename.concat repo_root
    "test/fixtures/tool_call_quality_benchmark/evidence_runs.json"

let load_fixture () =
  let repo_root = Sys.getcwd () in
  let cases =
    match Tool_call_quality_benchmark.load_cases_from_file (fixture_cases repo_root) with
    | Ok v -> v
    | Error msg -> fail ("load_cases_from_file failed: " ^ msg)
  in
  let runs =
    match Tool_call_quality_benchmark.load_runs_from_file (fixture_runs repo_root) with
    | Ok v -> v
    | Error msg -> fail ("load_runs_from_file failed: " ^ msg)
  in
  (cases, runs)

let find_row ~provider ~model ~keeper rows =
  List.find
    (fun (row : Tool_call_quality_benchmark.summary_row) ->
      row.provider = provider
      && row.model = model
      && row.keeper_profile = keeper)
    rows

let json_check_status_completed : Tool_call_quality_benchmark.json_check =
  {
    path = "$.status";
    equals = Some (`String "completed");
    contains = None;
    min_int = None;
    present = None;
  }

let selector_case ?(forbidden_tools = []) ?(forbidden_selectors = []) () :
    Tool_call_quality_benchmark.benchmark_case =
  {
    id = "selector_case";
    prompt = "synthetic selector scoring case";
    category = Tool_call_quality_benchmark.Tool_use;
    keeper_profiles = [ "bench-selector" ];
    forbidden_tools;
    forbidden_selectors;
    max_tool_calls = 3;
    success_checks = [ json_check_status_completed ];
    arg_checks = [];
    recovery_policy = None;
  }

let selector_tool_call ?route_evidence tool_name :
    Tool_call_quality_benchmark.tool_call =
  {
    tool_name;
    success = true;
    input = `Assoc [];
    output = None;
    route_evidence;
    duration_ms = None;
  }

let selector_run tool_calls : Tool_call_quality_benchmark.evidence_run =
  {
    case_id = "selector_case";
    provider = "provider-d";
    model = "model-d-5.4";
    keeper_profile = "bench-selector";
    run_id = None;
    repeat_index = None;
    prompt_fingerprint = None;
    task_success = Some true;
    final_output = Some "completed";
    final_result = Some (`Assoc [ ("status", `String "completed") ]);
    latency_ms = None;
    input_tokens = None;
    output_tokens = None;
    cost_usd = None;
    status = Tool_call_quality_benchmark.Run_ok;
    tool_calls;
  }

let test_load_cases_and_runs () =
  let cases, runs = load_fixture () in
  check int "case count" 4 (List.length cases);
  check int "run count" 7 (List.length runs)

let test_summary_rollups_and_stability () =
  let cases, runs = load_fixture () in
  let summary = Tool_call_quality_benchmark.summarize ~cases ~runs () in
  check int "cases total" 4 summary.cases_total;
  check int "runs total" 7 summary.runs_total;
  check int "scored runs" 6 summary.scored_runs;
  check int "unsupported runs" 1 summary.unsupported_runs;
  check int "runtime unreachable runs" 0 summary.runtime_unreachable_runs;
  let analyst_row =
    find_row
      ~provider:(Some "provider-d")
      ~model:(Some "model-d-5.4")
      ~keeper:(Some "bench-analyst")
      summary.grouped_by_provider_model_keeper
  in
  check int "analyst unique cases" 2 analyst_row.cases_total;
  check int "analyst passed cases" 2 analyst_row.cases_passed;
  check (option (float 0.0001)) "analyst stability score" (Some 1.0)
    analyst_row.stability_score;
  check int "analyst repeated groups" 1 analyst_row.repeated_case_groups;
  let executor_row =
    find_row
      ~provider:(Some "provider-d")
      ~model:(Some "model-d-5.4")
      ~keeper:(Some "bench-executor")
      summary.grouped_by_provider_model_keeper
  in
  check int "executor unique cases" 1 executor_row.cases_total;
  check int "executor passed cases" 0 executor_row.cases_passed;
  check bool "executor forbidden tool degraded selection"
    true (executor_row.tool_policy_rate < 1.0);
  let verifier_row =
    find_row
      ~provider:(Some "provider-d")
      ~model:(Some "model-d-5.4-mini")
      ~keeper:(Some "bench-verifier")
      summary.grouped_by_provider_model_keeper
  in
  check int "verifier unique cases" 1 verifier_row.cases_total;
  check int "verifier passed cases" 1 verifier_row.cases_passed;
  check bool "verifier stability below perfect"
    true
    (match verifier_row.stability_score with
     | Some value -> value < 1.0
     | None -> false);
  let provider_row =
    List.find
      (fun (row : Tool_call_quality_benchmark.summary_row) ->
        row.provider = Some "provider-d"
        && row.model = Some "model-d-5.4"
        && row.keeper_profile = None)
      summary.grouped_by_provider_model
  in
  check int "provider rollup unique cases" 2 provider_row.cases_total;
  check int "provider rollup passed cases" 1 provider_row.cases_passed

let test_csv_render_has_headers () =
  let cases, runs = load_fixture () in
  let summary = Tool_call_quality_benchmark.summarize ~cases ~runs () in
  let csv =
    Tool_call_quality_benchmark.summary_rows_to_csv
      ~view:Tool_call_quality_benchmark.By_provider_model_keeper summary
  in
  check bool "csv header includes stability column" true
    (String_util.contains_substring csv "stability_score");
  check bool "csv contains analyst keeper row" true
    (String_util.contains_substring csv "bench-analyst")

let test_forbidden_selector_matches_descriptor_evidence () =
  let route_evidence =
    `Assoc
      [
        ("descriptor_id", `String "masc.agent.card");
        ("runtime_handler", `String "Tool_masc_agent_dispatch");
      ]
  in
  let case =
    selector_case
      ~forbidden_selectors:[ Eval_tool_selector.Descriptor_id "masc.agent.card" ]
      ()
  in
  let run = selector_run [ selector_tool_call ~route_evidence "masc_agent_card" ] in
  match Tool_call_quality_benchmark.score_run ~cases:[ case ] run with
  | Some score ->
      check bool "selector degrades pass" false score.passed;
      check (float 0.0001) "tool selection failed" 0.0 score.tool_selection;
      check (float 0.0001) "unnecessary tool counted" 1.0
        score.unnecessary_tool_rate
  | None -> fail "score_run unexpectedly returned None"

let test_forbidden_selector_matches_eval_tag_evidence () =
  let route_evidence =
    `Assoc
      [
        ("descriptor_id", `String "masc.agent.card");
        ("eval_tags", `List [ `String "agent_profile_lookup" ]);
      ]
  in
  let case =
    selector_case
      ~forbidden_selectors:[ Eval_tool_selector.Eval_tag "agent_profile_lookup" ]
      ()
  in
  let run = selector_run [ selector_tool_call ~route_evidence "renamed_agent_card" ] in
  match Tool_call_quality_benchmark.score_run ~cases:[ case ] run with
  | Some score ->
      check bool "eval tag degrades pass" false score.passed;
      check (float 0.0001) "tool selection failed" 0.0 score.tool_selection
  | None -> fail "score_run unexpectedly returned None"

let test_loader_parses_forbidden_selectors () =
  let path = Filename.temp_file "tool-call-quality-selectors" ".json" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      Fs_compat.save_file path
        {|{
  "cases": [
    {
      "id": "selector_case",
      "prompt": "synthetic selector case",
      "category": "tool_use",
      "keeper_profiles": ["bench-selector"],
      "forbidden_tools": [],
      "forbidden_selectors": [
        {"type": "descriptor_id", "value": "masc.agent.card"},
        {"type": "receipt_label", "key": "family", "value": "profile_lookup"}
      ],
      "max_tool_calls": 3,
      "success_checks": [
        {"path": "$.status", "equals": "completed"}
      ],
      "arg_checks": []
    }
  ]
}|};
      match Tool_call_quality_benchmark.load_cases_from_file path with
      | Ok [ case ] ->
          check int "selector count" 2
            (List.length case.Tool_call_quality_benchmark.forbidden_selectors)
      | Ok cases ->
          fail
            (Printf.sprintf "expected one parsed case, got %d"
               (List.length cases))
      | Error msg -> fail ("load_cases_from_file failed: " ^ msg))

let () =
  run "tool_call_quality_benchmark"
    [
      ("benchmark", [
           test_case "loads fixture corpus" `Quick test_load_cases_and_runs;
           test_case "summarizes rollups and stability" `Quick
             test_summary_rollups_and_stability;
           test_case "renders csv" `Quick test_csv_render_has_headers;
           test_case "forbidden selector matches descriptor evidence" `Quick
             test_forbidden_selector_matches_descriptor_evidence;
           test_case "forbidden selector matches eval tag evidence" `Quick
             test_forbidden_selector_matches_eval_tag_evidence;
           test_case "loader parses forbidden selectors" `Quick
             test_loader_parses_forbidden_selectors;
         ]);
    ]
