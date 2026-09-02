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
          test_case "every row carries the join key" `Quick (fun () ->
              (* The counters are keyed by the internal name, which is the one
                 name a request never contains. Without the public names beside
                 it a count cannot be lined up against the tool schemas a turn
                 carried, which is the join the schema budget is decided on. *)
              let report = Tool_unified.summary_report () in
              let open Yojson.Safe.Util in
              List.iter
                (fun key ->
                  List.iter
                    (fun row ->
                      let _ = row |> member "name" |> to_string in
                      let _ = row |> member "public_names" |> to_list in
                      ())
                    (report |> member key |> to_list))
                [ "top_20"; "by_tool"; "never_called" ]);
          test_case "the report carries the whole distribution" `Quick (fun () ->
              (* Deciding which schemas earn their place in every request needs
                 the whole distribution, not its head. [top_20] stays the head
                 of [by_tool] for readers that only want the busiest tools. *)
              let report = Tool_unified.summary_report () in
              let open Yojson.Safe.Util in
              let by_tool = report |> member "by_tool" |> to_list in
              let top_20 = report |> member "top_20" |> to_list in
              check int "by_tool covers every called tool"
                (report |> member "distinct_tools_called" |> to_int)
                (List.length by_tool);
              check bool "top_20 is no longer than by_tool" true
                (List.length top_20 <= List.length by_tool);
              let name row = row |> member "name" |> to_string in
              let rec prefix short long =
                match short, long with
                | [], _ -> true
                | a :: rest_a, b :: rest_b ->
                  String.equal (name a) (name b) && prefix rest_a rest_b
                | _ :: _, [] -> false
              in
              check bool "top_20 is the head of by_tool" true
                (prefix top_20 by_tool);
              check int "never_called names match their count"
                (report |> member "never_called_count" |> to_int)
                (report |> member "never_called" |> to_list |> List.length));
          test_case "a counted tool names what the model calls it" `Quick
            (fun () ->
              Tool_registry.reset ();
              Tool_metrics.clear ();
              Fun.protect
                ~finally:(fun () ->
                  Tool_registry.reset ();
                  Tool_metrics.clear ())
                (fun () ->
                  Tool_metrics.record
                    (make_completed ~name:"tool_execute" ~duration_ms:5.0);
                  let report = Tool_unified.summary_report () in
                  let open Yojson.Safe.Util in
                  match report |> member "by_tool" |> to_list with
                  | [ row ] ->
                    check string "counted under the internal name" "tool_execute"
                      (row |> member "name" |> to_string);
                    (* The descriptors are a static list in the module, so this
                       holds in any process and the assertion cannot pass by
                       finding nothing. A tool the model can call must name
                       itself; an empty list here would mean the join key is
                       absent exactly where it is needed. *)
                    let public =
                      List.map to_string (row |> member "public_names" |> to_list)
                    in
                    check (list string) "the name the model calls it"
                      [ "Execute" ] public
                  | rows ->
                    failf "expected one counted tool, got %d" (List.length rows)));
        ] );
    ]
