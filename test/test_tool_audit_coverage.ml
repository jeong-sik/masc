(** Coverage tests for Tool_audit — Audit query, stats, and governance

    Tests dispatch routing, handler execution, audit_event_to_json,
    read_audit_events, and helper functions
    for 3 tools: masc_audit_query, masc_audit_stats, masc_governance_report
*)

module Tool_audit = Masc_mcp.Tool_audit
module Room = Masc_mcp.Room

let test_counter = ref 0

let temp_dir () =
  incr test_counter;
  let dir = Filename.temp_file
    (Printf.sprintf "test_audit_%d_" !test_counter) "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path)
      else Unix.unlink path
  in
  try rm dir with _ -> ()

let make_ctx () =
  let base_dir = temp_dir () in
  let config = Room.default_config base_dir in
  ignore (Room.init config ~agent_name:(Some "test-agent"));
  let ctx = { Tool_audit.config } in
  (ctx, base_dir)

(* ============================================================
   Dispatch routing tests
   ============================================================ *)

let test_dispatch_unknown () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_audit.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) in
  Alcotest.(check bool) "unknown returns None" true (result = None);
  cleanup_dir base_dir

let test_dispatch_audit_query () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_audit.dispatch ctx ~name:"masc_audit_query" ~args:(`Assoc []) in
  Alcotest.(check bool) "audit_query dispatches" true (result <> None);
  cleanup_dir base_dir

let test_dispatch_audit_stats () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_audit.dispatch ctx ~name:"masc_audit_stats" ~args:(`Assoc []) in
  Alcotest.(check bool) "audit_stats dispatches" true (result <> None);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — audit_query
   ============================================================ *)

let test_audit_query_empty () =
  let ctx, base_dir = make_ctx () in
  let (ok, msg) = Tool_audit.handle_audit_query ctx (`Assoc []) in
  Alcotest.(check bool) "empty query succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_audit_query_with_filters () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("agent", `String "test-agent");
    ("event_type", `String "tool_call");
    ("limit", `Int 10);
    ("since_hours", `Float 12.0);
  ] in
  let (ok, msg) = Tool_audit.handle_audit_query ctx args in
  Alcotest.(check bool) "filtered query succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   Handler tests — audit_stats
   ============================================================ *)

let test_audit_stats_empty () =
  let ctx, base_dir = make_ctx () in
  let (ok, msg) = Tool_audit.handle_audit_stats ctx (`Assoc []) in
  Alcotest.(check bool) "empty stats succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

let test_audit_stats_with_agent () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [("agent", `String "test-agent")] in
  let (ok, msg) = Tool_audit.handle_audit_stats ctx args in
  Alcotest.(check bool) "agent filter succeeds" true ok;
  Alcotest.(check bool) "has response" true (String.length msg > 0);
  cleanup_dir base_dir

(* ============================================================
   audit_event_to_json tests
   ============================================================ *)

let test_event_to_json_with_detail () =
  let event : Tool_audit.audit_event = {
    timestamp = 1234567890.0;
    agent = "test-agent";
    event_type = "tool_call";
    success = true;
    detail = Some "test detail";
  } in
  let json = Tool_audit.audit_event_to_json event in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "agent field" "test-agent"
    (json |> member "agent" |> to_string);
  Alcotest.(check string) "event_type field" "tool_call"
    (json |> member "event_type" |> to_string);
  Alcotest.(check bool) "success field" true
    (json |> member "success" |> to_bool)

let test_event_to_json_no_detail () =
  let event : Tool_audit.audit_event = {
    timestamp = 1234567890.0;
    agent = "test-agent";
    event_type = "auth_success";
    success = true;
    detail = None;
  } in
  let json = Tool_audit.audit_event_to_json event in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "detail is null" true
    (json |> member "detail" = `Null)

(* ============================================================
   read_audit_events tests
   ============================================================ *)

let test_read_audit_events_empty () =
  let ctx, base_dir = make_ctx () in
  let events = Tool_audit.read_audit_events ctx.config ~since:0.0 in
  Alcotest.(check (list unit)) "empty events" []
    (List.map (fun _ -> ()) events);
  cleanup_dir base_dir

(* ============================================================
   Helper function tests
   ============================================================ *)

let test_get_string_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check string) "extracts string" "value"
    (Tool_audit.get_string args "key" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  Alcotest.(check string) "uses default" "default"
    (Tool_audit.get_string args "key" "default")

let test_get_string_opt_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check (option string)) "extracts Some" (Some "value")
    (Tool_audit.get_string_opt args "key")

let test_get_string_opt_missing () =
  let args = `Assoc [] in
  Alcotest.(check (option string)) "returns None" None
    (Tool_audit.get_string_opt args "key")

let test_get_int_present () =
  let args = `Assoc [("key", `Int 42)] in
  Alcotest.(check int) "extracts int" 42
    (Tool_audit.get_int args "key" 0)

let test_get_int_missing () =
  let args = `Assoc [] in
  Alcotest.(check int) "uses default" 99
    (Tool_audit.get_int args "key" 99)

let test_get_float_present () =
  let args = `Assoc [("key", `Float 3.14)] in
  Alcotest.(check (float 0.001)) "extracts float" 3.14
    (Tool_audit.get_float args "key" 0.0)

let test_get_float_from_int () =
  let args = `Assoc [("key", `Int 42)] in
  Alcotest.(check (float 0.001)) "int to float" 42.0
    (Tool_audit.get_float args "key" 0.0)

let test_get_float_missing () =
  let args = `Assoc [] in
  Alcotest.(check (float 0.001)) "uses default" 1.5
    (Tool_audit.get_float args "key" 1.5)

(* ============================================================
   Test runner
   ============================================================ *)

let () =
  Alcotest.run "Tool_audit" [
    ("dispatch", [
      Alcotest.test_case "unknown returns None" `Quick test_dispatch_unknown;
      Alcotest.test_case "audit_query dispatches" `Quick test_dispatch_audit_query;
      Alcotest.test_case "audit_stats dispatches" `Quick test_dispatch_audit_stats;
    ]);
    ("audit_query", [
      Alcotest.test_case "empty query" `Quick test_audit_query_empty;
      Alcotest.test_case "with filters" `Quick test_audit_query_with_filters;
    ]);
    ("audit_stats", [
      Alcotest.test_case "empty stats" `Quick test_audit_stats_empty;
      Alcotest.test_case "with agent filter" `Quick test_audit_stats_with_agent;
    ]);
    ("audit_event_to_json", [
      Alcotest.test_case "with detail" `Quick test_event_to_json_with_detail;
      Alcotest.test_case "no detail" `Quick test_event_to_json_no_detail;
    ]);
    ("read_audit_events", [
      Alcotest.test_case "empty log" `Quick test_read_audit_events_empty;
    ]);
    ("helpers", [
      Alcotest.test_case "get_string present" `Quick test_get_string_present;
      Alcotest.test_case "get_string missing" `Quick test_get_string_missing;
      Alcotest.test_case "get_string_opt present" `Quick test_get_string_opt_present;
      Alcotest.test_case "get_string_opt missing" `Quick test_get_string_opt_missing;
      Alcotest.test_case "get_int present" `Quick test_get_int_present;
      Alcotest.test_case "get_int missing" `Quick test_get_int_missing;
      Alcotest.test_case "get_float present" `Quick test_get_float_present;
      Alcotest.test_case "get_float from int" `Quick test_get_float_from_int;
      Alcotest.test_case "get_float missing" `Quick test_get_float_missing;
    ]);
  ]
