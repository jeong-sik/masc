open Alcotest

let test_dir () =
  let tmp = Filename.temp_file "masc_research_loop" "" in
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

let sample_entry id description : Research_loop.experiment_entry =
  let hypothesis : Research_loop.hypothesis =
    {
      description;
      target_file = "lib/example.ml";
      rationale = "test";
      patch = "";
      old_text = "";
      new_text = "";
    }
  in
  let metric : Research_metric.t =
    {
      build_ok = true;
      test_pass_rate = 1.0;
      test_total = 1;
      test_passed = 1;
      loc_delta = 3;
      files_changed = 1;
      build_seconds = 0.1;
      test_seconds = 0.2;
      binary_changed = true;
      status = Research_metric.Keep;
      error_message = "";
    }
  in
  { id; hypothesis; metric }

let read_lines path =
  let content = Fs_compat.load_file path in
  String.split_on_char '\n' content
  |> List.filter (fun line -> line <> "")

let test_log_result_writes_header_once () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let results_file = Filename.concat dir "results.tsv" in
      Research_loop.log_result
        ~results_file ~entry:(sample_entry "exp-1" "first");
      Research_loop.log_result
        ~results_file ~entry:(sample_entry "exp-2" "second");
      let lines = read_lines results_file in
      check int "header + two rows" 3 (List.length lines);
      check string "header preserved"
        "experiment\tbuild_ok\ttest_pass_rate\tloc_delta\tfiles_changed\tstatus\tdescription"
        (List.nth lines 0);
      check bool "first row contains exp-1" true
        (String.starts_with ~prefix:"exp-1\t1\t1.0000\t3\t1\tkeep\tfirst" (List.nth lines 1));
      check bool "second row contains exp-2" true
        (String.starts_with ~prefix:"exp-2\t1\t1.0000\t3\t1\tkeep\tsecond" (List.nth lines 2)))

let test_log_result_is_best_effort_on_open_failure () =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let results_file = Filename.concat dir "missing/results.tsv" in
      Research_loop.log_result
        ~results_file ~entry:(sample_entry "exp-fail" "best-effort");
      check bool "missing dir still absent" false (Sys.file_exists results_file))

let () =
  run "research_loop"
    [
      ( "log_result",
        [
          test_case "writes header once across repeated appends" `Quick
            test_log_result_writes_header_once;
          test_case "open failure stays best effort" `Quick
            test_log_result_is_best_effort_on_open_failure;
        ] );
    ]
