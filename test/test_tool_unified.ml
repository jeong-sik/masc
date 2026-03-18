(** Tests for Tool_unified — unified tool query interface. *)

module Tool_unified = Masc_mcp.Tool_unified
module Tool_catalog = Masc_mcp.Tool_catalog
module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_registry = Masc_mcp.Tool_registry

let () =
  Eio_main.run @@ fun _env ->
  let open Alcotest in
  run "Tool_unified"
    [
      ( "tool_info",
        [
          test_case "known essential tool returns correct tier" `Quick (fun () ->
              let info = Tool_unified.tool_info "masc_join" in
              check string "tier" "essential"
                (Tool_catalog.tier_to_string info.tier));
          test_case "unknown tool returns full tier" `Quick (fun () ->
              let info = Tool_unified.tool_info "__test_unknown_xyz" in
              check string "tier" "full"
                (Tool_catalog.tier_to_string info.tier));
        ] );
      ( "tool_info_to_json",
        [
          test_case "JSON has required fields" `Quick (fun () ->
              let info = Tool_unified.tool_info "masc_status" in
              let json = Tool_unified.tool_info_to_json info in
              let open Yojson.Safe.Util in
              check string "name" "masc_status"
                (json |> member "name" |> to_string);
              check string "tier" "essential"
                (json |> member "tier" |> to_string);
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
              let _ = report |> member "tier_distribution" in
              let _ = report |> member "dispatch_v2_enabled" |> to_bool in
              let _ = report |> member "registered_count" |> to_int in
              ());
          test_case "tier_distribution has all tiers" `Quick (fun () ->
              let report = Tool_unified.summary_report () in
              let open Yojson.Safe.Util in
              let dist = report |> member "tier_distribution" in
              let _ = dist |> member "essential" |> to_int in
              let _ = dist |> member "standard" |> to_int in
              let _ = dist |> member "full" |> to_int in
              ());
        ] );
    ]
