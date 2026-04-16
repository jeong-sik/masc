let find_entry ~module_name ~message =
  Log.Ring.recent ~limit:50 ~module_filter:module_name ()
  |> List.find_opt (fun (entry : Log.Ring.entry) -> String.equal entry.message message)

let latest_seq () =
  match Log.Ring.recent ~limit:1 () with
  | (entry : Log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let test_legacy_traceln_records_metadata () =
  let module_name = "TestLogLegacy" in
  let message =
    Printf.sprintf "[WARN] legacy warning %f" (Unix.gettimeofday ())
  in
  Log.legacy_traceln ~module_name message;
  match find_entry ~module_name ~message with
  | None -> Alcotest.fail "legacy traceln entry not found"
  | Some (entry : Log.Ring.entry) ->
      Alcotest.(check string) "source" "legacy_traceln" entry.source;
      Alcotest.(check string) "normalized level" "WARN" entry.normalized_level;
      Alcotest.(check bool) "legacy classified" true entry.legacy_classified

let test_recent_since_seq_returns_only_new_entries () =
  let module_name = "TestLogDelta" in
  let baseline = latest_seq () in
  let info_message =
    Printf.sprintf "delta info %f" (Unix.gettimeofday ())
  in
  let warn_message =
    Printf.sprintf "delta warn %f" (Unix.gettimeofday ())
  in
  Log.info ~ctx:module_name "%s" info_message;
  Log.warn ~ctx:module_name "%s" warn_message;
  let entries =
    Log.Ring.recent ~limit:10 ~module_filter:module_name ~since_seq:baseline ()
  in
  Alcotest.(check (list string)) "delta messages"
    [ warn_message; info_message ]
    (List.map (fun (entry : Log.Ring.entry) -> entry.message) entries)

let oas_record ?(level = Agent_sdk.Log.Info) ~module_name ~message fields =
  Agent_sdk.Log.
    {
      ts = Unix.gettimeofday ();
      level;
      module_name;
      message;
      fields;
      trace_id = None;
      span_id = None;
    }

let test_oas_bridge_interpolates_placeholder_messages () =
  let rendered =
    Masc_mcp.Oas_log_bridge.render_record_message
      (oas_record
         ~module_name:"agent_tools"
         ~message:"tool %s: correction_pipeline fixed %d field(s)"
         [ Agent_sdk.Log.S ("tool", "keeper_github");
           Agent_sdk.Log.I ("fixes", 2) ])
  in
  Alcotest.(check string) "placeholder message rendered"
    "tool keeper_github: correction_pipeline fixed 2 field(s)"
    rendered

let test_oas_bridge_normalizes_generic_correction_messages () =
  let rendered =
    Masc_mcp.Oas_log_bridge.render_record_message
      (oas_record
         ~module_name:"agent_tools"
         ~message:"correction_pipeline fixed tool input fields"
         [ Agent_sdk.Log.S ("tool", "keeper_github");
           Agent_sdk.Log.I ("fixes", 2) ])
  in
  Alcotest.(check string) "generic correction message normalized"
    "tool keeper_github: correction_pipeline fixed 2 field(s)"
    rendered

let test_oas_bridge_promotes_mcp_server_failures_to_error () =
  let level =
    Masc_mcp.Oas_log_bridge.effective_level
      (oas_record
         ~level:Agent_sdk.Log.Warn
         ~module_name:"agent_config"
         ~message:"MCP server failed"
         [ Agent_sdk.Log.S ("server", "demo");
           Agent_sdk.Log.S ("error", "connection refused") ])
  in
  Alcotest.(check string) "mcp server failure promoted" "ERROR"
    (Log.level_to_string level)

let test_oas_bridge_promotes_context_injector_failures_to_error () =
  let level =
    Masc_mcp.Oas_log_bridge.effective_level
      (oas_record
         ~level:Agent_sdk.Log.Warn
         ~module_name:"agent_turn"
         ~message:"context_injector raised"
         [ Agent_sdk.Log.S ("tool", "keeper_fs_read");
           Agent_sdk.Log.S ("error", "boom") ])
  in
  Alcotest.(check string) "context injector failure promoted" "ERROR"
    (Log.level_to_string level)

let test_oas_bridge_promotes_missing_approval_callback_to_error () =
  let level =
    Masc_mcp.Oas_log_bridge.effective_level
      (oas_record
         ~level:Agent_sdk.Log.Warn
         ~module_name:"agent_tools"
         ~message:"ApprovalRequired but no approval callback — executing"
         [ Agent_sdk.Log.S ("tool", "keeper_bash");
           Agent_sdk.Log.S ("agent", "demo") ])
  in
  Alcotest.(check string) "approval callback gap promoted" "ERROR"
    (Log.level_to_string level)

let () =
  Alcotest.run "Masc_log" [
    ( "ring",
      [
        Alcotest.test_case "legacy traceln records metadata" `Quick
          test_legacy_traceln_records_metadata;
        Alcotest.test_case "recent since_seq returns only new entries" `Quick
          test_recent_since_seq_returns_only_new_entries;
        Alcotest.test_case
          "oas bridge interpolates placeholder messages"
          `Quick test_oas_bridge_interpolates_placeholder_messages;
        Alcotest.test_case
          "oas bridge normalizes generic correction messages"
          `Quick test_oas_bridge_normalizes_generic_correction_messages;
        Alcotest.test_case
          "oas bridge promotes MCP server failures"
          `Quick test_oas_bridge_promotes_mcp_server_failures_to_error;
        Alcotest.test_case
          "oas bridge promotes context injector failures"
          `Quick test_oas_bridge_promotes_context_injector_failures_to_error;
        Alcotest.test_case
          "oas bridge promotes missing approval callback"
          `Quick test_oas_bridge_promotes_missing_approval_callback_to_error;
      ] );
  ]
