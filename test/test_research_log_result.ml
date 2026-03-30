(** Test Research_loop.log_result — regression for fstat header detection. *)

open Research_loop
open Research_metric

let dummy_entry id =
  { id;
    hypothesis = {
      description = "test hypothesis";
      target_file = "test.ml";
      rationale = "test";
      patch = "";
      old_text = "";
      new_text = "";
    };
    metric = {
      build_ok = true;
      test_pass_rate = 1.0;
      test_total = 1;
      test_passed = 1;
      loc_delta = 0;
      files_changed = 1;
      build_seconds = 0.1;
      test_seconds = 0.2;
      binary_changed = false;
      status = Keep;
      error_message = "";
    };
  }

let with_tmp_dir f =
  let dir = Filename.temp_dir "test_research_" "" in
  Fun.protect ~finally:(fun () ->
    Array.iter (fun name -> Sys.remove (Filename.concat dir name))
      (Sys.readdir dir);
    Unix.rmdir dir) (fun () -> f dir)

(** Repeated log_result should produce exactly one header line. *)
let test_no_duplicate_header () =
  with_tmp_dir (fun dir ->
    let results_file = Filename.concat dir "results.tsv" in
    let e1 = dummy_entry "exp-001" in
    let e2 = dummy_entry "exp-002" in
    log_result ~results_file ~entry:e1;
    log_result ~results_file ~entry:e2;
    let ic = open_in results_file in
    let lines = ref [] in
    (try while true do lines := input_line ic :: !lines done
     with End_of_file -> close_in ic);
    let lines = List.rev !lines in
    let header_count =
      List.length (List.filter (fun l -> String.length l > 0 &&
        String.sub l 0 (min 10 (String.length l)) = "experiment") lines)
    in
    Alcotest.(check int) "exactly one header" 1 header_count;
    Alcotest.(check int) "header + 2 data lines" 3 (List.length lines))

(** First call on a new file creates the header. *)
let test_new_file_gets_header () =
  with_tmp_dir (fun dir ->
    let results_file = Filename.concat dir "results.tsv" in
    log_result ~results_file ~entry:(dummy_entry "exp-001");
    let ic = open_in results_file in
    let first_line = input_line ic in
    close_in ic;
    Alcotest.(check bool) "starts with header"
      true (String.length first_line > 0 &&
            String.sub first_line 0 10 = "experiment"))

(** Missing parent directory: best-effort, no crash. *)
let test_missing_dir_no_crash () =
  let results_file = "/tmp/nonexistent_dir_9999/results.tsv" in
  (* Should not raise *)
  log_result ~results_file ~entry:(dummy_entry "exp-001")

let () =
  Alcotest.run "research_log_result" [
    "log_result", [
      Alcotest.test_case "no duplicate header on repeated append" `Quick
        test_no_duplicate_header;
      Alcotest.test_case "new file gets header" `Quick
        test_new_file_gets_header;
      Alcotest.test_case "missing dir no crash" `Quick
        test_missing_dir_no_crash;
    ];
  ]
