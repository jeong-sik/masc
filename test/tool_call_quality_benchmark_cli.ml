open Masc_mcp

let write_file path contents =
  Fs_compat.mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let summary_rows_json view (summary : Tool_call_quality_benchmark.benchmark_summary) =
  let rows =
    match view with
    | Tool_call_quality_benchmark.By_provider_model_keeper ->
        summary.grouped_by_provider_model_keeper
    | Tool_call_quality_benchmark.By_provider_model ->
        summary.grouped_by_provider_model
    | Tool_call_quality_benchmark.By_keeper_profile ->
        summary.grouped_by_keeper_profile
  in
  `List (List.map Tool_call_quality_benchmark.summary_row_to_yojson rows)

let parse_csv_arg value =
  value
  |> String.split_on_char ','
  |> List.map String.trim
  |> List.filter (fun item -> item <> "")

let () =
  let repo_root = Sys.getcwd () in
  let cases_path =
    ref (Tool_call_quality_benchmark.default_case_set_path ~repo_root)
  in
  let evidence_path =
    ref (Tool_call_quality_benchmark.default_evidence_path ~repo_root)
  in
  let format = ref "json" in
  let artifact_dir = ref "" in
  let emit_canary_path = ref "" in
  let view = ref "provider-model-keeper" in
  let model_filters : string list ref = ref [] in
  let keeper_filters : string list ref = ref [] in
  let specs =
    [
      ("--cases", Arg.Set_string cases_path, "Path to tool-call benchmark case set JSON");
      ("--evidence", Arg.Set_string evidence_path, "Path to evidence runs JSON");
      ("--format", Arg.Set_string format, "Output format: json or csv");
      ("--artifact-dir", Arg.Set_string artifact_dir, "Write summary artifacts to this directory");
      ("--emit-canary", Arg.Set_string emit_canary_path, "Write keeper benchmark canary recommendation JSON to this path");
      ("--view", Arg.Set_string view, "Summary view: provider-model-keeper, provider-model, keeper");
      ("--models",
       Arg.String (fun value -> model_filters := parse_csv_arg value),
       "Comma-separated provider:model filters");
      ("--keepers",
       Arg.String (fun value -> keeper_filters := parse_csv_arg value),
       "Comma-separated keeper profile filters");
    ]
  in
  let usage = "tool_call_quality_benchmark_cli [--cases PATH] [--evidence PATH]" in
  Arg.parse specs (fun _ -> ()) usage;
  let cases =
    match Tool_call_quality_benchmark.load_cases_from_file !cases_path with
    | Ok v -> v
    | Error msg ->
        prerr_endline ("load_cases_from_file failed: " ^ msg);
        exit 1
  in
  let runs =
    match Tool_call_quality_benchmark.load_runs_from_file !evidence_path with
    | Ok v -> v
    | Error msg ->
        prerr_endline ("load_runs_from_file failed: " ^ msg);
        exit 1
  in
  let summary =
    Tool_call_quality_benchmark.summarize ~cases ~runs
      ~model_filters:!model_filters ~keeper_filters:!keeper_filters ()
  in
  let canary_manifest =
    Keeper_benchmark_canary.build_manifest summary
  in
  let view =
    match String.lowercase_ascii (String.trim !view) with
    | "provider-model-keeper" -> Tool_call_quality_benchmark.By_provider_model_keeper
    | "provider-model" -> Tool_call_quality_benchmark.By_provider_model
    | "keeper" -> Tool_call_quality_benchmark.By_keeper_profile
    | other -> failwith ("unknown --view: " ^ other)
  in
  let output =
    match String.lowercase_ascii (String.trim !format) with
    | "json" ->
        `Assoc
          [
            ("cases_path", `String !cases_path);
            ("evidence_path", `String !evidence_path);
            ("summary", Tool_call_quality_benchmark.benchmark_summary_to_yojson summary);
            ("keeper_benchmark_canary",
             Keeper_benchmark_canary.manifest_to_yojson canary_manifest);
            ("rows", summary_rows_json view summary);
          ]
        |> Yojson.Safe.pretty_to_string
    | "csv" ->
        Tool_call_quality_benchmark.summary_rows_to_csv ~view summary
    | other -> failwith ("unknown --format: " ^ other)
  in
  if String.trim !artifact_dir <> "" then (
    let ext =
      match String.lowercase_ascii (String.trim !format) with
      | "csv" -> "summary.csv"
      | _ -> "summary.json"
    in
    write_file (Filename.concat !artifact_dir ext) output);
  let canary_output_path =
    match String.trim !emit_canary_path, String.trim !artifact_dir with
    | path, _ when path <> "" -> Some path
    | "", artifact_dir when artifact_dir <> "" ->
        Some (Filename.concat artifact_dir "keeper_model_recommendations.json")
    | _ -> None
  in
  (match canary_output_path with
   | Some path ->
       write_file path
         (Keeper_benchmark_canary.manifest_to_yojson canary_manifest
          |> Yojson.Safe.pretty_to_string)
   | None -> ());
  print_string output;
  if String.length output = 0 || output.[String.length output - 1] <> '\n' then
    print_newline ()
