open Alcotest
open Yojson.Safe.Util

module Kcf = Masc_mcp.Keeper_callback_failure
module P = Masc_mcp.Prometheus
module Tcg = Masc_mcp.Telemetry_coverage_gap

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else Sys.remove path

let make_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String "phase-0-4-callback-keeper");
          ("agent_name", `String "phase-0-4-callback-keeper");
          ("trace_id", `String "trace-phase-0-4-callback");
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
          ("last_model_used", `String "llama:auto");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let contains ~needle haystack =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    needle_len = 0
    || (idx + needle_len <= haystack_len
       && (String.sub haystack idx needle_len = needle || loop (idx + 1)))
  in
  loop 0

let test_record_pins_metric_and_gap_schema () =
  let base_dir = Filename.temp_dir "masc-callback-gap-" "" in
  Fun.protect ~finally:(fun () -> rm_rf base_dir) (fun () ->
      let meta = make_meta () in
      let callback = "on_compaction_started" in
      let cb_labels = [ ("callback", callback) ] in
      let gap_labels =
        [
          ("source", "keeper_lifecycle_callback");
          ("producer", callback);
          ("dashboard_surface", "keeper_lifecycle");
          ("stale_reason", "callback_exception");
        ]
      in
      let before_cb =
        P.metric_value_or_zero P.metric_keeper_lifecycle_callback_failures
          ~labels:cb_labels ()
      in
      let before_gap =
        P.metric_value_or_zero P.metric_telemetry_coverage_gap
          ~labels:gap_labels ()
      in
      Kcf.record ~base_dir ~meta ~callback
        (Failure "synthetic phase 0.4 callback failure");
      check (float 0.0001) "callback failure metric increments"
        (before_cb +. 1.0)
        (P.metric_value_or_zero P.metric_keeper_lifecycle_callback_failures
           ~labels:cb_labels ());
      check (float 0.0001) "coverage gap metric increments"
        (before_gap +. 1.0)
        (P.metric_value_or_zero P.metric_telemetry_coverage_gap
           ~labels:gap_labels ());
      match Tcg.read_recent ~masc_root:base_dir ~n:1 with
      | [ row ] ->
          check string "schema" "masc.telemetry_coverage_gap.v1"
            (row |> member "schema" |> to_string);
          check string "source" "keeper_lifecycle_callback"
            (row |> member "source" |> to_string);
          check string "producer" callback
            (row |> member "producer" |> to_string);
          check string "durable_store" "keeper_lifecycle_events"
            (row |> member "durable_store" |> to_string);
          check string "dashboard_surface" "keeper_lifecycle"
            (row |> member "dashboard_surface" |> to_string);
          check string "stale_reason" "callback_exception"
            (row |> member "stale_reason" |> to_string);
          check string "keeper_name" "phase-0-4-callback-keeper"
            (row |> member "keeper_name" |> to_string);
          check string "trace_id" "trace-phase-0-4-callback"
            (row |> member "trace_id" |> to_string);
          check bool "error contains exception message" true
            (contains (row |> member "error" |> to_string)
               ~needle:"synthetic phase 0.4 callback failure")
      | rows ->
          failf "expected one telemetry coverage gap row, got %d"
            (List.length rows))

let () =
  run "keeper_callback_failure_telemetry"
    [
      ( "record",
        [
          test_case "pins callback failure metric and gap schema" `Quick
            test_record_pins_metric_and_gap_schema;
        ] );
    ]
