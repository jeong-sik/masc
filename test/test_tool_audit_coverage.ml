(** Coverage tests for Tool_audit — Audit query, stats, and governance

    Tests dispatch routing, handler execution, audit_event_to_json,
    read_audit_events, and helper functions
    for 3 tools: masc_audit_query, masc_audit_stats, masc_governance_report
*)
module Tool_args = Masc_mcp.Tool_args

module Tool_audit = Masc_mcp.Tool_audit
module Room = Masc_mcp.Room
module Audit_log = Masc_mcp.Audit_log

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
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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
    details = Some (`Assoc [("tool_name", `String "masc_status")]);
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
    details = None;
  } in
  let json = Tool_audit.audit_event_to_json event in
  let open Yojson.Safe.Util in
  Alcotest.(check bool) "detail is null" true
    (json |> member "detail" = `Null);
  Alcotest.(check bool) "details is null" true
    (json |> member "details" = `Null)

(* ============================================================
   read_audit_events tests
   ============================================================ *)

let test_read_audit_events_empty () =
  let ctx, base_dir = make_ctx () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      let events =
        Tool_audit.read_audit_events ctx.config
          ~since:(Unix.gettimeofday () +. 0.001)
      in
      Alcotest.(check (list unit)) "no later events" []
        (List.map (fun _ -> ()) events))

let test_read_audit_events_reads_canonical_store_and_normalizes_tool_call () =
  let ctx, base_dir = make_ctx () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      Audit_log.log_action ctx.config ~agent_id:"test-agent"
        ~action:(Audit_log.ToolCall "masc_status")
        ~room_id:"default"
        ~details:(`Assoc [("tool_name", `String "masc_status")])
        ~outcome:Audit_log.Success ();
      let events = Tool_audit.read_audit_events ctx.config ~since:0.0 in
      let tool_calls =
        List.filter
          (fun (event : Tool_audit.audit_event) ->
            String.equal event.event_type "tool_call")
          events
      in
      match tool_calls with
      | [event] ->
          Alcotest.(check string) "normalized event type" "tool_call"
            event.event_type;
          Alcotest.(check (option string)) "detail remains empty" None event.detail;
          Alcotest.(check bool) "details preserved" true
            (match event.details with Some (`Assoc _) -> true | _ -> false)
      | _ -> Alcotest.fail "expected one normalized tool_call event")

let test_audit_stats_counts_tool_call_prefixes () =
  let ctx, base_dir = make_ctx () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_dir)
    (fun () ->
      Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
      Audit_log.log_action ctx.config ~agent_id:"test-agent"
        ~action:(Audit_log.ToolCall "masc_status")
        ~room_id:"default" ~details:`Null ~outcome:Audit_log.Success ();
      let (ok, msg) = Tool_audit.handle_audit_stats ctx (`Assoc []) in
      Alcotest.(check bool) "stats succeeds" true ok;
      let json = Yojson.Safe.from_string msg in
      let open Yojson.Safe.Util in
      let agents = json |> member "agents" |> to_list in
      let matching =
        List.find_opt
          (fun agent_json ->
            match agent_json |> member "agent_id" with
            | `String "test-agent" -> true
            | _ -> false)
          agents
      in
      match matching with
      | Some agent_json ->
          Alcotest.(check int) "tool call counted" 1
            (agent_json |> member "tool_calls" |> to_int)
      | None -> Alcotest.fail "expected stats for test-agent")

(* ============================================================
   Helper function tests
   ============================================================ *)

let test_get_string_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check string) "extracts string" "value"
    (Tool_args.get_string args "key" "default")

let test_get_string_missing () =
  let args = `Assoc [] in
  Alcotest.(check string) "uses default" "default"
    (Tool_args.get_string args "key" "default")

let test_get_string_opt_present () =
  let args = `Assoc [("key", `String "value")] in
  Alcotest.(check (option string)) "extracts Some" (Some "value")
    (Tool_args.get_string_opt args "key")

let test_get_string_opt_missing () =
  let args = `Assoc [] in
  Alcotest.(check (option string)) "returns None" None
    (Tool_args.get_string_opt args "key")

let test_get_int_present () =
  let args = `Assoc [("key", `Int 42)] in
  Alcotest.(check int) "extracts int" 42
    (Tool_args.get_int args "key" 0)

let test_get_int_missing () =
  let args = `Assoc [] in
  Alcotest.(check int) "uses default" 99
    (Tool_args.get_int args "key" 99)

let test_get_float_present () =
  let args = `Assoc [("key", `Float 3.14)] in
  Alcotest.(check (float 0.001)) "extracts float" 3.14
    (Tool_args.get_float args "key" 0.0)

let test_get_float_from_int () =
  let args = `Assoc [("key", `Int 42)] in
  Alcotest.(check (float 0.001)) "int to float" 42.0
    (Tool_args.get_float args "key" 0.0)

let test_get_float_missing () =
  let args = `Assoc [] in
  Alcotest.(check (float 0.001)) "uses default" 1.5
    (Tool_args.get_float args "key" 1.5)

(* ============================================================
   Audit trail (trace_id linking) tests
   ============================================================ *)

let test_audit_entry_trace_id_in_json () =
  let entry : Audit_log.audit_entry = {
    timestamp = 1000000.0;
    agent_id = "operator";
    action = Audit_log.GovernanceDecision "confirm";
    room_id = None;
    details = `Assoc [("action_type", `String "room_pause")];
    outcome = Audit_log.Success;
    cost_estimate = None;
    token_count = None;
    trace_id = Some "ops_abc123";
  } in
  let json = Audit_log.entry_to_json entry in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "trace_id present" "ops_abc123"
    (json |> member "trace_id" |> to_string);
  Alcotest.(check string) "action contains decision"
    "governance_decision:confirm"
    (json |> member "action" |> to_string)

let test_audit_entry_no_trace_id () =
  let entry : Audit_log.audit_entry = {
    timestamp = 1000000.0;
    agent_id = "test";
    action = Audit_log.Join;
    room_id = None;
    details = `Null;
    outcome = Audit_log.Success;
    cost_estimate = None;
    token_count = None;
    trace_id = None;
  } in
  let json = Audit_log.entry_to_json entry in
  let keys = match json with `Assoc pairs -> List.map fst pairs | _ -> [] in
  Alcotest.(check bool) "trace_id absent from JSON" false
    (List.mem "trace_id" keys)

let test_entry_of_json_with_trace_id () =
  let json = `Assoc [
    ("timestamp", `Float 1000000.0);
    ("agent_id", `String "operator");
    ("action", `String "governance_decision:deny");
    ("room_id", `Null);
    ("details", `Null);
    ("outcome", `Assoc [("status", `String "success")]);
    ("trace_id", `String "ops_xyz789");
  ] in
  match Audit_log.entry_of_json json with
  | Some entry ->
    Alcotest.(check (option string)) "trace_id parsed" (Some "ops_xyz789") entry.trace_id;
    (match entry.action with
     | Audit_log.GovernanceDecision "deny" -> ()
     | _ -> Alcotest.fail "expected GovernanceDecision deny")
  | None -> Alcotest.fail "entry_of_json returned None"

let test_entry_of_json_without_trace_id () =
  let json = `Assoc [
    ("timestamp", `Float 1000000.0);
    ("agent_id", `String "test");
    ("action", `String "join");
    ("room_id", `Null);
    ("details", `Null);
    ("outcome", `Assoc [("status", `String "success")]);
  ] in
  match Audit_log.entry_of_json json with
  | Some entry ->
    Alcotest.(check (option string)) "trace_id is None" None entry.trace_id
  | None -> Alcotest.fail "entry_of_json returned None"

let test_governance_decision_roundtrip () =
  let action = Audit_log.GovernanceDecision "expired" in
  let s = Audit_log.action_to_string action in
  Alcotest.(check string) "serialized" "governance_decision:expired" s;
  let parsed = Audit_log.string_to_action s in
  match parsed with
  | Audit_log.GovernanceDecision "expired" -> ()
  | _ -> Alcotest.fail "roundtrip mismatch"

let test_dispatch_audit_trail () =
  let ctx, base_dir = make_ctx () in
  let result = Tool_audit.dispatch ctx ~name:"masc_audit_trail" ~args:(`Assoc []) in
  Alcotest.(check bool) "audit_trail dispatches" true (result <> None);
  cleanup_dir base_dir

let test_handle_audit_trail_with_trace_id () =
  let ctx, base_dir = make_ctx () in
  let args = `Assoc [
    ("trace_id", `String "ops_test_12345678");
    ("since_hours", `Float 720.0);
  ] in
  let (ok, msg) = Tool_audit.handle_audit_trail ctx args in
  Alcotest.(check bool) "succeeds" true ok;
  let json = Yojson.Safe.from_string msg in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "trace_id_filter echoed" "ops_test_12345678"
    (json |> member "trace_id_filter" |> to_string);
  Alcotest.(check int) "count is 0 for empty log" 0
    (json |> member "count" |> to_int);
  cleanup_dir base_dir

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
      Alcotest.test_case "counts tool_call prefixes" `Quick
        test_audit_stats_counts_tool_call_prefixes;
    ]);
    ("audit_event_to_json", [
      Alcotest.test_case "with detail" `Quick test_event_to_json_with_detail;
      Alcotest.test_case "no detail" `Quick test_event_to_json_no_detail;
    ]);
    ("read_audit_events", [
      Alcotest.test_case "empty log" `Quick test_read_audit_events_empty;
      Alcotest.test_case "canonical store + normalization" `Quick
        test_read_audit_events_reads_canonical_store_and_normalizes_tool_call;
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
    ("audit_trail_trace_id", [
      Alcotest.test_case "entry includes trace_id in JSON" `Quick test_audit_entry_trace_id_in_json;
      Alcotest.test_case "entry omits trace_id when None" `Quick test_audit_entry_no_trace_id;
      Alcotest.test_case "entry_of_json parses trace_id" `Quick test_entry_of_json_with_trace_id;
      Alcotest.test_case "entry_of_json handles missing trace_id" `Quick test_entry_of_json_without_trace_id;
      Alcotest.test_case "governance_decision action roundtrip" `Quick test_governance_decision_roundtrip;
      Alcotest.test_case "audit_trail dispatches" `Quick test_dispatch_audit_trail;
      Alcotest.test_case "audit_trail with trace_id filter" `Quick test_handle_audit_trail_with_trace_id;
    ]);
  ]
