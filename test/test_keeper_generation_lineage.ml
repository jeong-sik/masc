open Alcotest

module KGL = Masc.Keeper_generation_lineage
module U = Yojson.Safe.Util

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_dir prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)

let with_temp_file prefix contents f =
  let path = Filename.temp_file prefix ".json" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents);
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)

let persistence_read_drop_total ~surface ~reason =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_persistence_read_drops
    ~labels:[("surface", surface); ("reason", reason)]
    ()

let meta_fixture ~name ~trace_id =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String name
        ; "agent_name", `String name
        ; "trace_id", `String trace_id
        ; "goal", `String "test lineage surface"
        ])
  with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("meta fixture failed: " ^ err)

let classify_identity_fields_marks_changed_and_dropped () =
  let inherited, changed, dropped =
    KGL.classify_identity_fields
      ~previous:
        [
          ("goal", "Keep the system coherent");
          ("instructions", "Always capture evidence");
          ("needs", "Operator feedback");
        ]
      ~current:
        [
          ("goal", "Keep the system coherent");
          ("instructions", "");
          ("needs", "Recent telemetry");
        ]
  in
  check (list string) "inherited fields" [ "goal" ] inherited;
  check (list string) "changed fields" [ "needs" ] changed;
  check (list string) "dropped fields" [ "instructions" ] dropped

let continuity_judgment_reports_missing_summary () =
  let judgment =
    KGL.continuity_judgment
      ~original:""
      ~received:"Goal: continue the current task"
  in
  check string "missing summary verdict" "unavailable" judgment.verdict;
  check bool "missing summary similarity absent" true
    (Option.is_none judgment.similarity)

let continuity_judgment_verifies_identical_summary () =
  let text =
    "Goal: finish lineage telemetry\nProgress: dashboard panel integrated"
  in
  let judgment = KGL.continuity_judgment ~original:text ~received:text in
  check string "identical summary verdict" "verified" judgment.verdict;
  check bool "similarity available" true (Option.is_some judgment.similarity)

let malformed_manifest_load_counts_read_drop () =
  let surface = "keeper_generation_lineage_manifest" in
  let reason = "entry_load_error" in
  let before = persistence_read_drop_total ~surface ~reason in
  with_temp_file "keeper-generation-lineage-bad-manifest" "{not-json"
    (fun path ->
      check bool "malformed manifest is absent" true
        (Option.is_none (KGL.load_json_file_opt path)));
  check (float 0.0001) "manifest read drop counted" (before +. 1.0)
    (persistence_read_drop_total ~surface ~reason)

let index_read_error_surfaces_in_surface_json () =
  let surface = "keeper_generation_lineage_index" in
  let reason = "entry_load_error" in
  let before = persistence_read_drop_total ~surface ~reason in
  with_temp_dir "keeper-generation-lineage-index-read-error" (fun base_path ->
    let config = Masc.Workspace.default_config base_path in
    let meta =
      meta_fixture
        ~name:"lineage-index-read-error"
        ~trace_id:"lineage-index-read-error-trace"
    in
    let index_path =
      Masc.Keeper_types_support.keeper_generation_index_path config meta.name
    in
    let (_ : string) = Masc.Keeper_fs.ensure_dir (Filename.dirname index_path) in
    Unix.mkdir index_path 0o700;
    let json = KGL.surface_json config meta ~recent_limit:6 in
    check int "recent count falls back to empty" 0 U.(json |> member "recent_count" |> to_int);
    check string "index read error path" index_path
      U.(json |> member "index_read_error" |> member "path" |> to_string);
    check bool "index read error detail is present" true
      (String.length U.(json |> member "index_read_error" |> member "detail" |> to_string)
       > 0));
  check (float 0.0001) "index read drop counted" (before +. 1.0)
    (persistence_read_drop_total ~surface ~reason)

let legacy_index_loader_reports_read_error_before_empty_fallback () =
  let surface = "keeper_generation_lineage_index" in
  let reason = "entry_load_error" in
  let before = persistence_read_drop_total ~surface ~reason in
  with_temp_dir "keeper-generation-lineage-legacy-index-read-error" (fun base_path ->
    let path = Filename.concat base_path "lineage-index.jsonl" in
    Unix.mkdir path 0o700;
    check int "legacy loader fallback rows" 0
      (List.length (KGL.load_jsonl_file path)));
  check (float 0.0001) "legacy loader read drop counted" (before +. 1.0)
    (persistence_read_drop_total ~surface ~reason)

let () =
  run "Keeper_generation_lineage"
    [
      ( "identity delta",
        [
          test_case "changed and dropped fields are classified" `Quick
            classify_identity_fields_marks_changed_and_dropped;
        ] );
      ( "continuity judgment",
        [
          test_case "missing continuity summary reports unavailable" `Quick
            continuity_judgment_reports_missing_summary;
          test_case "identical continuity summary verifies" `Quick
            continuity_judgment_verifies_identical_summary;
        ] );
      ( "persistence read drops",
        [
          test_case "malformed manifest load is counted" `Quick
            malformed_manifest_load_counts_read_drop;
          test_case "index read error surfaces in surface JSON" `Quick
            index_read_error_surfaces_in_surface_json;
          test_case "legacy index loader reports read error before fallback" `Quick
            legacy_index_loader_reports_read_error_before_empty_fallback;
        ] );
    ]
