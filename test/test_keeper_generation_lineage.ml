open Alcotest

module KGL = Masc.Keeper_generation_lineage

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

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

let () =
  run "Keeper_generation_lineage"
    [
      ( "identity delta",
        [
          test_case "changed and dropped fields are classified" `Quick
            classify_identity_fields_marks_changed_and_dropped;
        ] );
      ( "persistence read drops",
        [
          test_case "malformed manifest load is counted" `Quick
            malformed_manifest_load_counts_read_drop;
        ] );
    ]
