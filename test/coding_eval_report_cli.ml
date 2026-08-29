(** CLI entry point for the coding-outcome eval report (RFC-0396 W2,
    issue #28822 option (a)).

    Reads the case corpus and a [runs.jsonl] produced by
    [scripts/harness_coding_eval.sh], assembles the suite through
    [Coding_eval_report.build_suite], prints the report, and writes
    [REPORT.md] + [report.json] into the output directory. Exit 1 means a
    structural problem (unreadable corpus, malformed rows); a low pass rate
    is a result, not an error. *)

let usage = "coding_eval_report_cli --cases DIR --runs FILE --out DIR [--k N]"

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)
;;

let () =
  let cases_dir = ref "" in
  let runs_path = ref "" in
  let out_dir = ref "" in
  let k = ref 1 in
  let spec =
    [ "--cases", Arg.Set_string cases_dir, "Case corpus directory"
    ; "--runs", Arg.Set_string runs_path, "runs.jsonl produced by the runner"
    ; "--out", Arg.Set_string out_dir, "Output directory for REPORT.md / report.json"
    ; "--k", Arg.Set_int k, "k for pass@k (default 1)"
    ]
  in
  Arg.parse spec (fun anon -> raise (Arg.Bad ("unexpected argument: " ^ anon))) usage;
  let fail message =
    prerr_endline ("coding_eval_report_cli: " ^ message);
    exit 1
  in
  if !cases_dir = "" || !runs_path = "" || !out_dir = "" then fail usage;
  if !k < 1 then fail "--k must be at least 1";
  match Coding_eval_case.load_cases ~cases_dir:!cases_dir with
  | Error message -> fail message
  | Ok cases ->
    (match Coding_eval_report.rows_of_jsonl_file !runs_path with
     | Error message -> fail message
     | Ok rows ->
       (match Coding_eval_report.build_suite ~cases ~rows ~k:!k with
        | Error message -> fail message
        | Ok report ->
          let rendered = Coding_eval_report.render_report report in
          if not (Sys.file_exists !out_dir) then Sys.mkdir !out_dir 0o755;
          write_file (Filename.concat !out_dir "REPORT.md") rendered;
          write_file
            (Filename.concat !out_dir "report.json")
            (Yojson.Safe.pretty_to_string (Coding_eval_report.report_json report));
          print_string rendered))
;;
