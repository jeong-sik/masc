module Lib = Masc

open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_dashboard_perf" "" in
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

let ensure_dir path =
  let rec loop current =
    if current = "" || current = Filename.dirname current then ()
    else begin
      loop (Filename.dirname current);
      if not (Sys.file_exists current) then Unix.mkdir current 0o755
    end
  in
  loop path

let write_file path contents =
  ensure_dir (Filename.dirname path);
  Out_channel.with_open_text path (fun oc -> output_string oc contents)

let write_csv path rows =
  let body =
    String.concat "\n"
      ("benchmark,avg_ms,p50_ms,p95_ms,max_ms,notes" :: rows)
    ^ "\n"
  in
  write_file path body

let write_json path json =
  write_file path (Yojson.Safe.pretty_to_string json)

let set_mtime path value =
  Unix.utimes path value value

let with_temp_base f =
  let dir = test_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir dir) (fun () -> f dir)

let with_cwd dir f =
  let old = Sys.getcwd () in
  Unix.chdir dir;
  Fun.protect ~finally:(fun () -> Unix.chdir old) f

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let test_dashboard_perf_reads_root_benchmarks () =
  with_temp_base @@ fun base_path ->
  let config = Lib.Workspace.default_config base_path in
  let results_dir = Filename.concat base_path "benchmarks/results" in
  let baseline_file = Filename.concat results_dir "results_20260331_130000.csv" in
  let latest_file = Filename.concat results_dir "results_20260331_140000.csv" in
  write_csv baseline_file
    [
      "mcp_session_init,12,12,20,24,session";
      "mcp_read_status,5,5,9,11,source=live";
      "oas_runtime_status,140,138,165,190,configured_capacity=16;healthy_runtime_count=4";
      "oas_runtime_single,1000,980,1300,1450,measured_ceiling=1";
    ];
  write_csv latest_file
    [
      "mcp_session_init,9,9,14,18,session";
      "mcp_read_status,8,7,66,88,source=live";
      "oas_runtime_status,116,115,140,170,configured_capacity=16;healthy_runtime_count=4";
      "oas_runtime_single,866,850,1100,1260,measured_ceiling=1";
    ];
  write_json
    (Filename.chop_suffix latest_file ".csv" ^ ".meta.json")
    (`Assoc
      [
        ("started_at", `String "2026-03-31T14:00:00Z");
        ("pattern", `String "all");
        ("iterations", `Int 5);
        ("warmup_iterations", `Int 1);
        ("session_warmup_iterations", `Int 1);
        ("compare_baseline_file", `String baseline_file);
      ]);
  set_mtime baseline_file 1_000.0;
  set_mtime latest_file 2_000.0;
  let json = Server_dashboard_http.dashboard_perf_http_json config in
  let open Yojson.Safe.Util in
  check string "status" "ok" (json |> member "status" |> to_string);
  check string "result file" "benchmarks/results/results_20260331_140000.csv"
    (json |> member "source" |> member "result_file" |> to_string);
  check string "baseline file" "benchmarks/results/results_20260331_130000.csv"
    (json |> member "comparison" |> member "baseline_file" |> to_string);
  check int "improved count" 1
    (json |> member "comparison" |> member "verdict_counts" |> member "improved" |> to_int);
  check int "regressed count" 1
    (json |> member "comparison" |> member "verdict_counts" |> member "regressed" |> to_int);
  check int "stable count" 2
    (json |> member "comparison" |> member "verdict_counts" |> member "stable" |> to_int);
  check int "runtime avg" 866
    (json |> member "highlights" |> member "runtime_single" |> member "avg_ms" |> to_int);
  check string "runtime healthy tag" "4"
    (json |> member "highlights" |> member "runtime_status" |> member "note_tags"
     |> member "healthy_runtime_count" |> to_string);
  check string "top change benchmark" "oas_runtime_single"
    (json |> member "comparison" |> member "top_changes" |> index 0
     |> member "benchmark" |> to_string)

let test_dashboard_perf_reads_worktree_benchmarks () =
  with_temp_base @@ fun base_path ->
  let config = Lib.Workspace.default_config base_path in
  let workspace_root = Filename.concat base_path ".worktrees/feat-perf" in
  let worktree_results_dir = Filename.concat workspace_root "benchmarks/results" in
  let latest_file = Filename.concat worktree_results_dir "results_20260331_150000.csv" in
  write_csv latest_file
    [
      "mcp_session_init,7,7,9,12,session";
      "mcp_read_status,4,4,7,9,source=live";
      "oas_runtime_status,111,110,132,150,configured_capacity=16;healthy_runtime_count=4";
      "oas_runtime_single,820,805,1010,1160,measured_ceiling=1";
    ];
  set_mtime latest_file 3_000.0;
  with_env "MASC_BENCHMARK_RESULTS_DIR" worktree_results_dir @@ fun () ->
  let json = Server_dashboard_http.dashboard_perf_http_json config in
  let open Yojson.Safe.Util in
  check string "status" "ok" (json |> member "status" |> to_string);
  check string "worktree dir selected" ".worktrees/feat-perf/benchmarks/results"
    (json |> member "source" |> member "results_dir" |> to_string);
  check int "benchmark count" 4
    (json |> member "latest_run" |> member "benchmark_count" |> to_int);
  check string "runtime file tag" "1"
    (json |> member "highlights" |> member "runtime_single" |> member "note_tags"
     |> member "measured_ceiling" |> to_string)

let test_dashboard_perf_prefers_latest_scoped_artifact () =
  with_temp_base @@ fun base_path ->
  let config = Lib.Workspace.default_config base_path in
  let root_results_dir = Filename.concat base_path "benchmarks/results" in
  let root_file = Filename.concat root_results_dir "results_20260331_160000.csv" in
  let workspace_root = Filename.concat base_path ".worktrees/feat-perf" in
  let worktree_results_dir = Filename.concat workspace_root "benchmarks/results" in
  let worktree_file =
    Filename.concat worktree_results_dir "results_20260331_150000.csv"
  in
  write_csv root_file
    [
      "mcp_session_init,6,6,8,10,session";
      "oas_runtime_single,790,780,980,1100,measured_ceiling=1";
    ];
  write_csv worktree_file
    [
      "mcp_session_init,7,7,9,12,session";
      "oas_runtime_single,820,805,1010,1160,measured_ceiling=1";
    ];
  set_mtime worktree_file 2_000.0;
  set_mtime root_file 3_000.0;
  with_cwd workspace_root @@ fun () ->
  let json = Server_dashboard_http.dashboard_perf_http_json config in
  let open Yojson.Safe.Util in
  check string "status" "ok" (json |> member "status" |> to_string);
  check string "latest scoped file wins" "benchmarks/results/results_20260331_160000.csv"
    (json |> member "source" |> member "result_file" |> to_string)

let test_dashboard_perf_empty_shape () =
  with_temp_base @@ fun base_path ->
  let config = Lib.Workspace.default_config base_path in
  let json = Server_dashboard_http.dashboard_perf_http_json config in
  let open Yojson.Safe.Util in
  check string "status" "empty" (json |> member "status" |> to_string);
  check int "benchmarks empty" 0
    (json |> member "benchmarks" |> to_list |> List.length);
  check bool "comparison null" true
    (match json |> member "comparison" with `Null -> true | _ -> false)

let test_dashboard_perf_surfaces_csv_and_meta_read_errors () =
  with_temp_base @@ fun base_path ->
  let config = Lib.Workspace.default_config base_path in
  let results_dir = Filename.concat base_path "benchmarks/results" in
  let latest_file = Filename.concat results_dir "results_20260331_170000.csv" in
  write_file latest_file
    (String.concat "\n"
       [
         "benchmark,avg_ms,p50_ms,p95_ms,max_ms,notes";
         "mcp_session_init,9,9,14,18,session";
         "malformed,row";
         "mcp_read_status,nope,7,66,88,source=live";
       ]
     ^ "\n");
  write_file (Filename.chop_suffix latest_file ".csv" ^ ".meta.json") "{bad";
  set_mtime latest_file 4_000.0;
  let json = Server_dashboard_http.dashboard_perf_http_json config in
  let open Yojson.Safe.Util in
  check string "status" "degraded" (json |> member "status" |> to_string);
  check int "one valid benchmark kept" 1
    (json |> member "benchmarks" |> to_list |> List.length);
  check int "read errors surfaced" 3
    (json |> member "read_error_count" |> to_int);
  let error_kinds =
    json |> member "read_errors" |> to_list
    |> List.map (fun error -> error |> member "kind" |> to_string)
  in
  check (list string) "error kinds"
    [ "csv_row_parse_error"; "csv_number_parse_error"; "json_parse_error" ]
    error_kinds;
  check int "malformed row index" 3
    (json |> member "read_errors" |> index 0 |> member "line_index" |> to_int)

let () =
  run "dashboard_perf"
    [
      ( "dashboard_perf",
        [
          test_case "returns stable empty shape without artifacts" `Quick
            test_dashboard_perf_empty_shape;
          test_case "reads latest root benchmark artifacts" `Quick
            test_dashboard_perf_reads_root_benchmarks;
          test_case "falls back to worktree benchmark artifacts" `Quick
            test_dashboard_perf_reads_worktree_benchmarks;
          test_case "prefers latest artifact within scoped dirs" `Quick
            test_dashboard_perf_prefers_latest_scoped_artifact;
          test_case "surfaces CSV and meta read errors" `Quick
            test_dashboard_perf_surfaces_csv_and_meta_read_errors;
        ] );
    ]
