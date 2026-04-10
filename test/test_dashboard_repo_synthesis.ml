module Lib = Masc_mcp

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_repo_synthesis" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun f -> rm (Filename.concat path f));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  rm dir

let with_temp_base f =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () -> f dir)

let sample_run run_id =
  {
    Lib.Repo_synthesis_benchmark.benchmark_run_id = run_id;
    created_at = "2026-03-24T12:00:00Z";
    created_by = Some "tester";
    goal = "Answer repo synthesis questions";
    question = "What is the canonical benchmark path?";
    question_id = Some "cpv2-vs-supervisor";
    repo_root = "/tmp/repo";
    artifact_scope = [ "docs/COMMAND-PLANE-RUNBOOK.md" ];
    program_note = Some "keep answers evidence-backed";
    baseline_label = Some "single-agent";
    model = Some "auto";
    max_workers = 6;
    time_budget_sec = 900;
    workload_profile = "coding_task";
    operation_id = Some "op-123";
    trace_id = Some "trace-123";
    session_id = Some "ts-123";
    report_json_path = Some "/tmp/repo/.masc/team-sessions/ts-123/report.json";
    report_md_path = Some "/tmp/repo/.masc/team-sessions/ts-123/report.md";
    proof_json_path = Some "/tmp/repo/.masc/team-sessions/ts-123/proof.json";
    proof_md_path = Some "/tmp/repo/.masc/team-sessions/ts-123/proof.md";
    dataset_ref = Some "/tmp/repo/benchmark/repo_synthesis_question_set.json";
    case_refs = [ "cpv2-vs-supervisor" ];
    planned_worker_roles =
      [ "planner"; "code-explorer"; "doc-explorer"; "test-explorer" ];
    recommended_next_tools =
      [ "masc_operator_snapshot"; "masc_operation_checkpoint" ];
    status = "started";
  }

let sample_score =
  {
    Lib.Repo_synthesis_benchmark.answer_set_label = "swarm";
    question_count = 3;
    answered_count = 3;
    evidence_precision = 1.0;
    claim_coverage = 1.0;
    unsupported_claim_penalty = 0.0;
    avg_latency_ms = 900.0;
    composite_score = 0.9;
    per_question = [];
  }

let test_dashboard_lists_run_with_score () =
  with_temp_base @@ fun base_path ->
  let run = sample_run "rsb-1" in
  Lib.Repo_synthesis_benchmark.save_run ~base_path run;
  Lib.Repo_synthesis_benchmark.save_score ~base_path ~run_id:"rsb-1" sample_score;
  let json =
    Lib.Dashboard_http_repo_synthesis.repo_synthesis_benchmarks_json
      ~base_path ()
  in
  check int "one run" 1 Yojson.Safe.Util.(json |> member "total" |> to_int);
  check string "run id" "rsb-1"
    Yojson.Safe.Util.(
      json |> member "runs" |> index 0 |> member "run" |> member "benchmark_run_id"
      |> to_string);
  check (float 0.000001) "composite score" 0.9
    Yojson.Safe.Util.(
      json |> member "runs" |> index 0 |> member "score" |> member "composite_score"
      |> to_float)

let test_dashboard_detail_reads_saved_run () =
  with_temp_base @@ fun base_path ->
  let run = sample_run "rsb-2" in
  Lib.Repo_synthesis_benchmark.save_run ~base_path run;
  match
    Lib.Dashboard_http_repo_synthesis.repo_synthesis_benchmark_detail_json
      ~base_path ~run_id:"rsb-2"
  with
  | Error msg -> fail msg
  | Ok json ->
      check string "question id" "cpv2-vs-supervisor"
        Yojson.Safe.Util.(
          json |> member "run" |> member "question_id" |> to_string);
      check string "session id" "ts-123"
        Yojson.Safe.Util.(
          json |> member "run" |> member "session_id" |> to_string)

let test_dashboard_detail_rejects_invalid_run_id () =
  with_temp_base @@ fun base_path ->
  match
    Lib.Dashboard_http_repo_synthesis.repo_synthesis_benchmark_detail_json
      ~base_path ~run_id:"../../etc/passwd"
  with
  | Ok _ -> fail "expected invalid run id to be rejected"
  | Error msg ->
      check bool "invalid run id error" true
        (String.starts_with ~prefix:"invalid repo synthesis benchmark run id:" msg)

let () =
  run "dashboard_repo_synthesis"
    [
      ("dashboard_repo_synthesis",
       [
         test_case "lists run with score" `Quick test_dashboard_lists_run_with_score;
         test_case "detail reads run" `Quick test_dashboard_detail_reads_saved_run;
         test_case "detail rejects invalid run id" `Quick
           test_dashboard_detail_rejects_invalid_run_id;
       ]);
    ]
