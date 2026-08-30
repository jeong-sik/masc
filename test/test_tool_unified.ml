(** Tests for Tool_unified — unified tool query interface. *)

module Tool_unified = Masc.Tool_unified
module Tool_catalog = Tool_catalog
module Tool_dispatch = Tool_dispatch
module Tool_registry = Tool_registry

let make_completed ~name ~duration_ms =
  Tool_result.Completed
    { Tool_result.tool_name = name
    ; data = `Null
    ; metadata = None
    ; duration_ms
    }

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let open Alcotest in
  run "Tool_unified"
    [
      ( "tool_info",
        [
          test_case "known tool exposes lifecycle metadata" `Quick (fun () ->
              let info = Tool_unified.tool_info "masc_bind" in
              check string "lifecycle" "active"
                (Tool_catalog.lifecycle_to_string info.lifecycle));
          test_case "unknown tool still returns info" `Quick (fun () ->
              let info = Tool_unified.tool_info "__test_unknown_xyz" in
              check string "visibility" "hidden"
                (Tool_catalog.visibility_to_string info.visibility));
        ] );
      ( "tool_info_to_json",
        [
          test_case "JSON has required fields" `Quick (fun () ->
              let info = Tool_unified.tool_info "masc_status" in
              let json = Tool_unified.tool_info_to_json info in
              let open Yojson.Safe.Util in
              check string "name" "masc_status"
                (json |> member "name" |> to_string);
              check string "visibility" "default"
                (json |> member "visibility" |> to_string);
              (* is_read_only depends on init, just check field exists *)
              let _ = json |> member "is_read_only" |> to_bool in
              ());
        ] );
      ( "summary_report",
        [
          test_case "report has required keys" `Quick (fun () ->
              let report = Tool_unified.summary_report () in
              let open Yojson.Safe.Util in
              let _ = report |> member "total_calls" |> to_int in
              let _ = report |> member "distinct_tools_called" |> to_int in
              let _ = report |> member "top_20" |> to_list in
              let _ = report |> member "never_called_count" |> to_int in
              let _ = report |> member "tool_distribution" in
              (* RFC-0084 host-config-cleanup-J — dispatch_v2_enabled removed *)
              let _ = report |> member "registered_count" |> to_int in
              let persistence = report |> member "persistence" in
              check string
                "persistence schema"
                "masc.tool_metrics.persistence.v1"
                (persistence |> member "schema" |> to_string);
              check string
                "persistence scope"
                "current_process"
                (persistence |> member "scope" |> to_string);
              check bool
                "runtime identity present"
                true
                (persistence |> member "runtime_instance_id" |> to_string |> String.length > 0);
              check bool
                "process start present"
                true
                (persistence |> member "process_started_at" |> to_string |> String.length > 0);
              let _ = persistence |> member "queue_depth" |> to_int in
              let _ = persistence |> member "retry_queue_depth" |> to_int in
              let _ = persistence |> member "in_flight_records" |> to_int in
              let _ = persistence |> member "spooling_records" |> to_int in
              let _ = persistence |> member "spool_backed_queue_depth" |> to_int in
              let _ = persistence |> member "queue_full_dropped_records" |> to_int in
              let _ = persistence |> member "append_failed_records" |> to_int in
              let _ = persistence |> member "spool_write_failed_records" |> to_int in
              let _ = persistence |> member "spool_delete_failed_records" |> to_int in
              check bool
                "missing last trigger remains null"
                true
                (persistence |> member "last_flush_trigger" = `Null);
              check bool
                "missing last error remains null"
                true
                (persistence |> member "last_append_error" = `Null);
              check bool
                "missing last spool error remains null"
                true
                (persistence |> member "last_spool_error" = `Null);
              ());
          test_case "tool_distribution has visibility buckets" `Quick (fun () ->
              let report = Tool_unified.summary_report () in
              let open Yojson.Safe.Util in
              let dist = report |> member "tool_distribution" in
              let _ = dist |> member "total" |> to_int in
              let _ = dist |> member "public" |> to_int in
              let _ = dist |> member "visible" |> to_int in
              let _ = dist |> member "hidden" |> to_int in
              ());
          test_case "report uses restart-safe metrics snapshot" `Quick (fun () ->
              Tool_registry.reset ();
              Tool_metrics.clear ();
              Fun.protect
                ~finally:(fun () ->
                  Tool_registry.reset ();
                  Tool_metrics.clear ())
                (fun () ->
                  Tool_metrics.record
                    (make_completed ~name:"masc_status" ~duration_ms:12.0);
                  Tool_metrics.record
                    (make_completed ~name:"masc_status" ~duration_ms:18.0);
                  check int
                    "registry intentionally empty"
                    0
                    (Tool_registry.total_calls ());
                  let report = Tool_unified.summary_report () in
                  let open Yojson.Safe.Util in
                  check int "metrics total" 2
                    (report |> member "total_calls" |> to_int);
                  check int "metrics distinct" 1
                    (report |> member "distinct_tools_called" |> to_int);
                  match report |> member "top_20" |> to_list with
                  | first :: _ ->
                    check string "top tool" "masc_status"
                      (first |> member "name" |> to_string);
                    check int "top count" 2
                      (first |> member "call_count" |> to_int)
                  | [] -> fail "expected one top tool"));
        ] );
    ]
