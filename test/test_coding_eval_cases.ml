(** No-LLM contracts for the coding-eval corpus and report pipeline
    (RFC-0396 W1/W2).

    Three contracts keep the corpus honest without touching a model:
    every case declaration decodes; a pristine workspace fails its verify
    (the task starts red); the solution overlay turns verify green (the task
    is solvable and verify measures the right thing). The report pipeline is
    pinned on a fixed two-row evidence file, including the row-consistency
    guard that refuses a row disagreeing with its own verdict. *)

open Alcotest

(* Dune runs a test from its build directory, so a bare relative path finds
   nothing. Same shape as test_keeper_sandbox_image_contract.ml: trust
   DUNE_SOURCEROOT only when the anchor is visible inside it, walk upwards
   otherwise, and fail loudly rather than skipping. *)
let corpus_anchor = Filename.concat "benchmarks" (Filename.concat "coding" "cases")

let rec find_source_root_from dir depth =
  if depth > 8
  then None
  else if Sys.file_exists (Filename.concat dir corpus_anchor)
  then Some dir
  else (
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_source_root_from parent (depth + 1))
;;

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root
    when String.trim root <> "" && Sys.file_exists (Filename.concat root corpus_anchor)
    -> root
  | _ ->
    (match find_source_root_from (Sys.getcwd ()) 0 with
     | Some root -> root
     | None ->
       Alcotest.fail
         (Printf.sprintf
            "could not locate %s from %s -- the corpus contract cannot run"
            corpus_anchor
            (Sys.getcwd ())))
;;

let cases_dir () = Filename.concat (source_root ()) corpus_anchor

let string_contains haystack needle =
  let h = String.length haystack and n = String.length needle in
  let rec loop i = i + n <= h && (String.sub haystack i n = needle || loop (i + 1)) in
  n = 0 || loop 0
;;

let temp_dir prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Sys.mkdir path 0o755;
  path
;;

let run_quiet command =
  (* /bin/sh via Sys.command; stdout/stderr are silenced so a red verify does
     not spam the suite log — the exit code is the entire verdict. *)
  Sys.command (command ^ " >/dev/null 2>&1")
;;

let copy_tree ~src ~dst =
  let code =
    run_quiet
      (Printf.sprintf "cp -R %s %s" (Filename.quote (src ^ "/.")) (Filename.quote dst))
  in
  if code <> 0 then Alcotest.failf "cp -R %s -> %s exited %d" src dst code
;;

let verify_exit ~case_dir ~(case : Coding_eval_case.t) ~workspace =
  run_quiet
    (Printf.sprintf
       "bash %s %s"
       (Filename.quote (Filename.concat case_dir case.verify))
       (Filename.quote workspace))
;;

let loaded_cases () =
  match Coding_eval_case.load_cases ~cases_dir:(cases_dir ()) with
  | Ok cases -> cases
  | Error message -> Alcotest.failf "corpus failed to load: %s" message
;;

let test_corpus_decodes () =
  let cases = loaded_cases () in
  check bool "at least one case" true (List.length cases >= 1);
  check
    bool
    "l1-calc-add present"
    true
    (List.exists (fun (c : Coding_eval_case.t) -> String.equal c.id "l1-calc-add") cases)
;;

let test_every_case_starts_red_and_solution_turns_green () =
  let cases = loaded_cases () in
  List.iter
    (fun (case : Coding_eval_case.t) ->
       let case_dir = Filename.concat (cases_dir ()) case.id in
       let workspace = temp_dir ("coding_eval_" ^ case.id ^ "_") in
       copy_tree ~src:(Filename.concat case_dir "workspace") ~dst:workspace;
       let pristine = verify_exit ~case_dir ~case ~workspace in
       check bool (case.id ^ " pristine verify fails") true (pristine <> 0);
       copy_tree ~src:(Filename.concat case_dir "solution") ~dst:workspace;
       let solved = verify_exit ~case_dir ~case ~workspace in
       check int (case.id ^ " solution verify passes") 0 solved)
    cases
;;

let test_case_json_rejects_undeclared_keys () =
  let json =
    `Assoc
      [ "id", `String "x"
      ; "level", `String "L1"
      ; "lang", `String "python"
      ; "timeout_sec", `Int 60
      ; "verify", `String "verify.sh"
      ; "prompt", `String "p"
      ; "description", `String "d"
      ; "extra", `String "nope"
      ]
  in
  match Coding_eval_case.of_json json with
  | Ok _ -> Alcotest.fail "expected the undeclared key to be rejected"
  | Error message ->
    check bool "error names the key" true (string_contains message "extra")
;;

let row_json
      ?(regression_exit = None)
      ?(edited_source_files = None)
      ?(edited_target_files = None)
      ?(build_exit = None)
      ~run_index
      ~status
      ~verify_exit
      ~passed
      ()
  =
  let int_or_null = function
    | Some code -> `Int code
    | None -> `Null
  in
  `Assoc
    [ "case_id", `String "l1-calc-add"
    ; "run_index", `Int run_index
    ; "run_id", `String (Printf.sprintf "run-%d" run_index)
    ; "provider", `String "ollama"
    ; "model", `String "test-model"
    ; "status", `String status
    ; "verify_exit", int_or_null verify_exit
    ; "regression_exit", int_or_null regression_exit
    ; "edited_source_files", int_or_null edited_source_files
    ; "edited_target_files", int_or_null edited_target_files
    ; "build_exit", int_or_null build_exit
    ; "passed", `Bool passed
    ; "duration_ms", `Int 1200
    ; "recorded_at", `Float 1700000000.0
    ; "tool_calls", `List [ `String "Read"; `String "Edit"; `String "Execute" ]
    ; "input_tokens", `Null
    ; "output_tokens", `Null
    ; "cost_usd", `Null
    ; "error", `Null
    ]
;;

let write_jsonl path rows =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       List.iter
         (fun row -> output_string channel (Yojson.Safe.to_string row ^ "\n"))
         rows)
;;

let test_report_pipeline_on_fixed_rows () =
  let cases = loaded_cases () in
  let dir = temp_dir "coding_eval_report_" in
  let runs_path = Filename.concat dir "runs.jsonl" in
  write_jsonl
    runs_path
    [ row_json ~run_index:1 ~status:"ok" ~verify_exit:(Some 0) ~passed:true ()
    ; row_json ~run_index:2 ~status:"ok" ~verify_exit:(Some 1) ~passed:false ()
    ];
  let rows =
    match Coding_eval_report.rows_of_jsonl_file runs_path with
    | Ok rows -> rows
    | Error message -> Alcotest.failf "rows failed to decode: %s" message
  in
  match Coding_eval_report.build_suite ~cases ~rows ~k:1 with
  | Error message -> Alcotest.failf "suite failed to build: %s" message
  | Ok report ->
    check int "total runs" 2 report.suite.total_runs;
    check (float 0.0001) "overall pass rate" 0.5 report.suite.overall_pass_rate;
    (match report.suite.results with
     | [ result ] ->
       check (float 0.0001) "pass@1 over n=2 c=1" 0.5 result.pass_at_k;
       check bool "n=2 is below the min-runs gate" false result.min_runs_met
     | results -> Alcotest.failf "expected one scenario result, got %d" (List.length results));
    let bucket_count bucket =
      List.assoc bucket report.bucket_counts
    in
    check int "verify_green bucket" 1 (bucket_count Coding_eval_report.Verify_green);
    check int "verify_red bucket" 1 (bucket_count Coding_eval_report.Verify_red);
    let rendered = Coding_eval_report.render_report report in
    check bool "report names the buckets" true (string_contains rendered "verify_red: 1")
;;

let test_row_disagreeing_with_its_verdict_is_refused () =
  match
    Coding_eval_report.row_of_json
      (row_json ~run_index:1 ~status:"ok" ~verify_exit:(Some 1) ~passed:true ())
  with
  | Ok _ -> Alcotest.fail "expected the inconsistent row to be refused"
  | Error message ->
    check bool "error says the row disagrees" true (string_contains message "disagrees")
;;

let base_case_fields =
  [ "id", `String "x"
  ; "level", `String "L1"
  ; "lang", `String "python"
  ; "timeout_sec", `Int 60
  ; "verify", `String "verify.sh"
  ; "prompt", `String "p"
  ; "description", `String "d"
  ]
;;

let test_test_files_defaults_to_check_sh () =
  match Coding_eval_case.of_json (`Assoc base_case_fields) with
  | Ok case ->
    check (list string) "default protected oracle" [ "check.sh" ] case.test_files
  | Error message -> Alcotest.failf "expected the default test_files, got: %s" message
;;

let test_test_files_rejects_traversal () =
  let json =
    `Assoc (base_case_fields @ [ "test_files", `List [ `String "../evil.sh" ] ])
  in
  match Coding_eval_case.of_json json with
  | Ok _ -> Alcotest.fail "expected the .. path to be rejected"
  | Error message ->
    check bool "error names the traversal" true (string_contains message "..")
;;

let write_text_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

(* The anti-gaming contract: a solution overlay may not ship its own copy of a
   protected test oracle, because the graded run restores that file from the
   case's canonical workspace. If the solution could carry [check.sh], a
   candidate could be graded against a test it authored. *)
let test_solution_may_not_ship_the_oracle () =
  let root = temp_dir "coding_eval_oracle_" in
  let case_id = "oracle-fixture" in
  let dir = Filename.concat root case_id in
  Sys.mkdir dir 0o755;
  Sys.mkdir (Filename.concat dir "workspace") 0o755;
  Sys.mkdir (Filename.concat dir "solution") 0o755;
  write_text_file
    (Filename.concat dir "case.json")
    (Yojson.Safe.to_string
       (`Assoc
           [ "id", `String case_id
           ; "level", `String "L1"
           ; "lang", `String "bash"
           ; "timeout_sec", `Int 60
           ; "verify", `String "verify.sh"
           ; "prompt", `String "p"
           ; "description", `String "d"
           ]));
  write_text_file
    (Filename.concat dir "verify.sh")
    "#!/usr/bin/env bash\nbash \"$1/check.sh\"\n";
  write_text_file
    (Filename.concat (Filename.concat dir "workspace") "check.sh")
    "exit 1\n";
  write_text_file
    (Filename.concat (Filename.concat dir "solution") "check.sh")
    "exit 0\n";
  match Coding_eval_case.load_case ~dir with
  | Ok _ -> Alcotest.fail "expected the solution-shipped oracle to be rejected"
  | Error message ->
    check bool "error names the oracle" true (string_contains message "check.sh")
;;

let test_case_json_accepts_regression () =
  let json = `Assoc (base_case_fields @ [ "regression", `String "regress.sh" ]) in
  match Coding_eval_case.of_json json with
  | Ok case ->
    check (option string) "regression parsed" (Some "regress.sh") case.regression
  | Error message -> Alcotest.failf "expected regression to parse, got: %s" message
;;

(* A regression guard that went red makes the run not-passed even when verify is
   green; a row claiming otherwise is refused, and one telling the consistent
   story decodes. *)
let test_regression_failure_gates_passed () =
  (match
     Coding_eval_report.row_of_json
       (row_json
          ~run_index:1
          ~status:"ok"
          ~verify_exit:(Some 0)
          ~regression_exit:(Some 1)
          ~passed:true
          ())
   with
   | Ok _ -> Alcotest.fail "expected a green-verify red-regression pass to be refused"
   | Error message ->
     check bool "error names regression" true (string_contains message "regression_exit"));
  match
    Coding_eval_report.row_of_json
      (row_json
         ~run_index:1
         ~status:"ok"
         ~verify_exit:(Some 0)
         ~regression_exit:(Some 1)
         ~passed:false
         ())
  with
  | Ok row -> check bool "regression failure is not a pass" false row.passed
  | Error message -> Alcotest.failf "consistent regression row should decode: %s" message
;;

let test_regressed_bucket () =
  match
    Coding_eval_report.row_of_json
      (row_json
         ~run_index:1
         ~status:"ok"
         ~verify_exit:(Some 0)
         ~regression_exit:(Some 1)
         ~passed:false
         ())
  with
  | Error message -> Alcotest.failf "row should decode: %s" message
  | Ok row ->
    check
      bool
      "green verify + red regression buckets as Regressed"
      true
      (Coding_eval_report.bucket_of_row row = Coding_eval_report.Regressed)
;;

let test_case_json_accepts_build () =
  let json = `Assoc (base_case_fields @ [ "build", `String "build.sh" ]) in
  match Coding_eval_case.of_json json with
  | Ok case -> check (option string) "build parsed" (Some "build.sh") case.build
  | Error message -> Alcotest.failf "expected build to parse, got: %s" message
;;

(* The verify-red trajectory buckets are decided by the deterministic file-delta
   signals, never by parsing output: no source edited is Gave_up, source but not
   the target is Off_target_edit, the target edited with a red build probe is
   Build_failed, and the target edited with no failing build is Wrong_solution. *)
let bucket_of_failed_row ?edited_source_files ?edited_target_files ?build_exit () =
  match
    Coding_eval_report.row_of_json
      (row_json
         ~run_index:1
         ~status:"ok"
         ~verify_exit:(Some 1)
         ?edited_source_files
         ?edited_target_files
         ?build_exit
         ~passed:false
         ())
  with
  | Ok row -> Coding_eval_report.bucket_of_row row
  | Error message -> Alcotest.failf "row should decode: %s" message
;;

let test_gave_up_bucket () =
  check
    bool
    "no source edited buckets as Gave_up"
    true
    (bucket_of_failed_row
       ~edited_source_files:(Some 0)
       ~edited_target_files:(Some 0)
       ()
     = Coding_eval_report.Gave_up)
;;

let test_off_target_edit_bucket () =
  check
    bool
    "source edited but not the target buckets as Off_target_edit"
    true
    (bucket_of_failed_row
       ~edited_source_files:(Some 2)
       ~edited_target_files:(Some 0)
       ()
     = Coding_eval_report.Off_target_edit)
;;

let test_build_failed_bucket () =
  check
    bool
    "target edited with a red build buckets as Build_failed"
    true
    (bucket_of_failed_row
       ~edited_source_files:(Some 1)
       ~edited_target_files:(Some 1)
       ~build_exit:(Some 1)
       ()
     = Coding_eval_report.Build_failed)
;;

let test_wrong_solution_bucket () =
  check
    bool
    "target edited, build green, still red buckets as Wrong_solution"
    true
    (bucket_of_failed_row
       ~edited_source_files:(Some 1)
       ~edited_target_files:(Some 1)
       ~build_exit:(Some 0)
       ()
     = Coding_eval_report.Wrong_solution)
;;

let test_uninstrumented_failure_stays_coarse () =
  check
    bool
    "a verify-red row with no trajectory signals stays Verify_red"
    true
    (bucket_of_failed_row () = Coding_eval_report.Verify_red)
;;

let () =
  run
    "coding_eval_cases"
    [ ( "corpus"
      , [ test_case "corpus decodes" `Quick test_corpus_decodes
        ; test_case
            "pristine red, solution green"
            `Quick
            test_every_case_starts_red_and_solution_turns_green
        ; test_case
            "case.json rejects undeclared keys"
            `Quick
            test_case_json_rejects_undeclared_keys
        ; test_case
            "test_files defaults to check.sh"
            `Quick
            test_test_files_defaults_to_check_sh
        ; test_case
            "test_files rejects path traversal"
            `Quick
            test_test_files_rejects_traversal
        ; test_case
            "solution may not ship the oracle"
            `Quick
            test_solution_may_not_ship_the_oracle
        ; test_case
            "case.json accepts a regression guard"
            `Quick
            test_case_json_accepts_regression
        ; test_case "case.json accepts a build probe" `Quick test_case_json_accepts_build
        ] )
    ; ( "report"
      , [ test_case "fixed rows pipeline" `Quick test_report_pipeline_on_fixed_rows
        ; test_case
            "inconsistent row refused"
            `Quick
            test_row_disagreeing_with_its_verdict_is_refused
        ; test_case
            "regression failure gates passed"
            `Quick
            test_regression_failure_gates_passed
        ; test_case "regressed bucket" `Quick test_regressed_bucket
        ; test_case "gave-up bucket" `Quick test_gave_up_bucket
        ; test_case "off-target-edit bucket" `Quick test_off_target_edit_bucket
        ; test_case "build-failed bucket" `Quick test_build_failed_bucket
        ; test_case "wrong-solution bucket" `Quick test_wrong_solution_bucket
        ; test_case
            "uninstrumented failure stays coarse"
            `Quick
            test_uninstrumented_failure_stays_coarse
        ] )
    ]
;;
