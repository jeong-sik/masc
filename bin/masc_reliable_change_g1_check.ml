open Reliable_change_g1

let usage =
  "masc_reliable_change_g1_check --manifest FILE --runs FILE [--out DIR]"
;;

let () =
  let manifest_path = ref "" in
  let runs_path = ref "" in
  let out_dir = ref "" in
  let spec =
    [ "--manifest", Arg.Set_string manifest_path, "Path to manifest.json"
    ; "--runs", Arg.Set_string runs_path, "Path to runs.jsonl"
    ; ( "--out"
      , Arg.Set_string out_dir
      , "Output directory for checker.json and summary.json (default: directory of runs.jsonl)" )
    ]
  in
  Arg.parse spec (fun anon -> raise (Arg.Bad ("unexpected argument: " ^ anon))) usage;
  let fail msg =
    output_string stderr ("masc_reliable_change_g1_check: " ^ msg ^ "\n");
    flush stderr;
    exit 1
  in
  if !manifest_path = "" || !runs_path = "" then fail usage;
  let target_out_dir =
    if !out_dir <> "" then !out_dir
    else Filename.dirname !runs_path
  in
  match load_manifest_file !manifest_path with
  | Error msg -> fail msg
  | Ok manifest ->
    match load_observations_file !runs_path with
    | Error msg -> fail msg
    | Ok observations ->
      let summary = check_observations ~manifest ~observations in
      if not (Sys.file_exists target_out_dir) then (
        try Unix.mkdir target_out_dir 0o755 with
        | Unix.Unix_error _ -> ()
      );
      let checker_path = Filename.concat target_out_dir "checker.json" in
      let summary_path = Filename.concat target_out_dir "summary.json" in
      (match write_checker_file checker_path summary with
       | Error msg -> fail msg
       | Ok () ->
         (match write_summary_file summary_path summary with
          | Error msg -> fail msg
          | Ok () ->
            let summary_json = summary_to_json summary in
            print_endline (Yojson.Safe.pretty_to_string summary_json);
            if summary.overall_passed then exit 0 else exit 2))
;;
