open Alcotest
open Masc_mcp

let fixture_cases repo_root =
  Filename.concat repo_root "benchmark/tool_call_quality_cases.json"
;;

let fixture_runs repo_root =
  Filename.concat repo_root "test/fixtures/tool_call_quality_benchmark/evidence_runs.json"
;;

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
  cases, runs
;;

let find_row ~provider ~model ~keeper rows =
  List.find
    (fun (row : Tool_call_quality_benchmark.summary_row) ->
       row.provider = provider && row.model = model && row.keeper_profile = keeper)
    rows
;;

let test_load_cases_and_runs () =
  let cases, runs = load_fixture () in
  check int "case count" 4 (List.length cases);
  check int "run count" 7 (List.length runs)
;;

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
      ~provider:(Some "openai")
      ~model:(Some "gpt-5.4")
      ~keeper:(Some "bench-analyst")
      summary.grouped_by_provider_model_keeper
  in
  check int "analyst unique cases" 2 analyst_row.cases_total;
  check int "analyst passed cases" 2 analyst_row.cases_passed;
  check
    (option (float 0.0001))
    "analyst stability score"
    (Some 1.0)
    analyst_row.stability_score;
  check int "analyst repeated groups" 1 analyst_row.repeated_case_groups;
  let executor_row =
    find_row
      ~provider:(Some "openai")
      ~model:(Some "gpt-5.4")
      ~keeper:(Some "bench-executor")
      summary.grouped_by_provider_model_keeper
  in
  check int "executor unique cases" 1 executor_row.cases_total;
  check int "executor passed cases" 0 executor_row.cases_passed;
  check bool "executor tool selection degraded" true (executor_row.correct_tool_rate < 1.0);
  let verifier_row =
    find_row
      ~provider:(Some "openai")
      ~model:(Some "gpt-5.4-mini")
      ~keeper:(Some "bench-verifier")
      summary.grouped_by_provider_model_keeper
  in
  check int "verifier unique cases" 1 verifier_row.cases_total;
  check int "verifier passed cases" 1 verifier_row.cases_passed;
  check
    bool
    "verifier stability below perfect"
    true
    (match verifier_row.stability_score with
     | Some value -> value < 1.0
     | None -> false);
  let provider_row =
    List.find
      (fun (row : Tool_call_quality_benchmark.summary_row) ->
         row.provider = Some "openai"
         && row.model = Some "gpt-5.4"
         && row.keeper_profile = None)
      summary.grouped_by_provider_model
  in
  check int "provider rollup unique cases" 2 provider_row.cases_total;
  check int "provider rollup passed cases" 1 provider_row.cases_passed
;;

let test_csv_render_has_headers () =
  let cases, runs = load_fixture () in
  let summary = Tool_call_quality_benchmark.summarize ~cases ~runs () in
  let csv =
    Tool_call_quality_benchmark.summary_rows_to_csv
      ~view:Tool_call_quality_benchmark.By_provider_model_keeper
      summary
  in
  check
    bool
    "csv header includes stability column"
    true
    (String_util.contains_substring csv "stability_score");
  check
    bool
    "csv contains analyst keeper row"
    true
    (String_util.contains_substring csv "bench-analyst")
;;

let () =
  run
    "tool_call_quality_benchmark"
    [ ( "benchmark"
      , [ test_case "loads fixture corpus" `Quick test_load_cases_and_runs
        ; test_case
            "summarizes rollups and stability"
            `Quick
            test_summary_rollups_and_stability
        ; test_case "renders csv" `Quick test_csv_render_has_headers
        ] )
    ]
;;
