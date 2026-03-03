(** Test suite for Mcp_server_eio module

    Tests the Eio-native MCP server implementation.
    Uses Eio_main.run for async test context.
*)

module Mcp_eio = Masc_mcp.Mcp_server_eio
module Mcp = Masc_mcp.Mcp_server

(* ===== Test Helpers ===== *)

let temp_dir () =
  let dir = Filename.temp_file "test_mcp_eio_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> rm (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  in
  try rm dir with _ -> ()

let contains_substring s needle =
  let s_len = String.length s in
  let n_len = String.length needle in
  let rec loop i =
    if i + n_len > s_len then false
    else if String.sub s i n_len = needle then true
    else loop (i + 1)
  in
  if n_len = 0 then true else loop 0

(* ===== Unit Tests for Type Re-exports ===== *)

let test_create_state () =
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  Alcotest.(check string) "base_path preserved"
    base_path state.room_config.base_path;
  cleanup_dir base_path

let test_type_compatibility () =
  (* Verify Mcp_server_eio.server_state is same type as Mcp_server.server_state *)
  let base_path = temp_dir () in
  let state : Mcp_eio.server_state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let _state2 : Mcp.server_state = state in  (* Type unification *)
  cleanup_dir base_path;
  Alcotest.(check pass) "types are compatible" () ()

(* ===== Unit Tests for Protocol Helpers ===== *)

let test_is_jsonrpc_v2 () =
  let valid = `Assoc [("jsonrpc", `String "2.0"); ("method", `String "test")] in
  let invalid = `Assoc [("jsonrpc", `String "1.0")] in
  let no_version = `Assoc [("method", `String "test")] in
  Alcotest.(check bool) "valid 2.0" true (Mcp_eio.is_jsonrpc_v2 valid);
  Alcotest.(check bool) "invalid 1.0" false (Mcp_eio.is_jsonrpc_v2 invalid);
  Alcotest.(check bool) "no version" false (Mcp_eio.is_jsonrpc_v2 no_version)

let test_jsonrpc_request_parsing () =
  let json = `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "initialize");
    ("params", `Assoc []);
  ] in
  match Mcp_eio.jsonrpc_request_of_yojson json with
  | Ok req ->
      Alcotest.(check string) "method" "initialize" req.method_;
      Alcotest.(check bool) "has id" true (req.id <> None)
  | Error msg ->
      Alcotest.fail ("Parse failed: " ^ msg)

let test_is_notification () =
  let with_id = `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "test");
  ] in
  let without_id = `Assoc [
    ("jsonrpc", `String "2.0");
    ("method", `String "notifications/initialized");
  ] in
  (match Mcp_eio.jsonrpc_request_of_yojson with_id with
   | Ok req -> Alcotest.(check bool) "with id" false (Mcp_eio.is_notification req)
   | Error _ -> Alcotest.fail "parse error");
  (match Mcp_eio.jsonrpc_request_of_yojson without_id with
   | Ok req -> Alcotest.(check bool) "without id" true (Mcp_eio.is_notification req)
   | Error _ -> Alcotest.fail "parse error")

let test_protocol_version () =
  let params = Some (`Assoc [("protocolVersion", `String "2025-03-26")]) in
  let version = Mcp_eio.protocol_version_from_params params in
  Alcotest.(check string) "version extracted" "2025-03-26" version;

  let normalized = Mcp_eio.normalize_protocol_version "unknown" in
  Alcotest.(check string) "normalized to default" "2025-11-25" normalized

(* ===== Unit Tests for Response Builders ===== *)

let test_make_response () =
  let response = Mcp_eio.make_response ~id:(`Int 42) (`String "result") in
  match response with
  | `Assoc fields ->
      let id = List.assoc "id" fields in
      let result = List.assoc "result" fields in
      Alcotest.(check bool) "has jsonrpc" true (List.mem_assoc "jsonrpc" fields);
      Alcotest.(check bool) "id is 42" true (id = `Int 42);
      Alcotest.(check bool) "result is string" true (result = `String "result")
  | _ -> Alcotest.fail "not an object"

let test_make_error () =
  let response = Mcp_eio.make_error ~id:(`Int 1) (-32600) "Invalid Request" in
  match response with
  | `Assoc fields ->
      let error = List.assoc "error" fields in
      (match error with
       | `Assoc error_fields ->
           let code = List.assoc "code" error_fields in
           Alcotest.(check bool) "error code" true (code = `Int (-32600))
       | _ -> Alcotest.fail "error not an object")
  | _ -> Alcotest.fail "not an object"

(* ===== Eio Integration Tests ===== *)

let test_handle_request_initialize () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "initialize");
    ("params", `Assoc [
      ("protocolVersion", `String "2025-11-25");
      ("capabilities", `Assoc []);
      ("clientInfo", `Assoc [
        ("name", `String "test");
        ("version", `String "1.0");
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in

  (match response with
   | `Assoc fields ->
       Alcotest.(check bool) "has result" true (List.mem_assoc "result" fields);
       (match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) ->
            Alcotest.(check bool) "has serverInfo" true
              (List.mem_assoc "serverInfo" result_fields);
            Alcotest.(check bool) "has capabilities" true
              (List.mem_assoc "capabilities" result_fields)
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");

  cleanup_dir base_path

let test_handle_request_tools_list () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 2);
    ("method", `String "tools/list");
    ("params", `Assoc []);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in

  (match response with
   | `Assoc fields ->
       Alcotest.(check bool) "has result" true (List.mem_assoc "result" fields);
       (match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) ->
            Alcotest.(check bool) "has tools" true
              (List.mem_assoc "tools" result_fields);
            (match List.assoc_opt "tools" result_fields with
             | Some (`List tools) ->
                 let names =
                   tools
                   |> List.filter_map (function
                        | `Assoc fields -> List.assoc_opt "name" fields
                        | _ -> None)
                   |> List.filter_map (function `String s -> Some s | _ -> None)
                 in
                 Alcotest.(check bool)
                   "contains trpg.dice.roll"
                   true
                   (List.mem "trpg.dice.roll" names);
                 Alcotest.(check bool)
                   "contains trpg.turn.advance"
                   true
                   (List.mem "trpg.turn.advance" names);
                 Alcotest.(check bool)
                   "contains trpg.stream.read"
                   true
                   (List.mem "trpg.stream.read" names);
                 Alcotest.(check bool)
                   "contains trpg.round.run"
                   true
                   (List.mem "trpg.round.run" names);
                 Alcotest.(check bool)
                   "contains masc_goal_upsert"
                   true
                   (List.mem "masc_goal_upsert" names);
                 Alcotest.(check bool)
                   "legacy masc_trpg_dice_roll hidden from list"
                   false
                   (List.mem "masc_trpg_dice_roll" names)
             | _ -> Alcotest.fail "tools not a list")
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");

  cleanup_dir base_path

let test_execute_tool_trpg_flow () =
  Eio_main.run @@ fun env ->
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let (ok_roll, roll_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_trpg_dice_roll"
      ~arguments:
        (`Assoc
          [
            ("room_id", `String "room-mcp-e2e");
            ("actor_id", `String "pc-1");
            ("action", `String "perception");
            ("stat_value", `Int 12);
            ("dc", `Int 10);
            ("raw_d20", `Int 15);
          ])
  in
  Alcotest.(check bool) "dice_roll success" true ok_roll;

  let (ok_turn, _turn_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_trpg_turn_advance"
      ~arguments:
        (`Assoc
          [
            ("room_id", `String "room-mcp-e2e");
            ("phase", `String "round");
          ])
  in
  Alcotest.(check bool) "turn_advance success" true ok_turn;

  let (ok_stream, stream_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_trpg_stream"
      ~arguments:(`Assoc [ ("room_id", `String "room-mcp-e2e") ])
  in
  Alcotest.(check bool) "stream success" true ok_stream;
  let stream_json = Yojson.Safe.from_string stream_msg in
  let count = stream_json |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int in
  Alcotest.(check bool) "stream has events" true (count >= 2);

  let (ok_stream_dice, stream_dice_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_trpg_stream"
      ~arguments:
        (`Assoc
          [
            ("room_id", `String "room-mcp-e2e");
            ("event_type", `String "dice.rolled");
          ])
  in
  Alcotest.(check bool) "stream event_type filter success" true ok_stream_dice;
  let stream_dice_json = Yojson.Safe.from_string stream_dice_msg in
  let dice_count =
    stream_dice_json |> Yojson.Safe.Util.member "count" |> Yojson.Safe.Util.to_int
  in
  Alcotest.(check int) "dice-only event count" 1 dice_count;

  let roll_json = Yojson.Safe.from_string roll_msg in
  let passed = roll_json |> Yojson.Safe.Util.member "roll" |> Yojson.Safe.Util.member "passed" |> Yojson.Safe.Util.to_bool in
  Alcotest.(check bool) "roll passed" true passed;

  cleanup_dir base_path

let test_execute_tool_trpg_validation () =
  Eio_main.run @@ fun env ->
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let (ok_missing, msg_missing) =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_trpg_turn_advance"
      ~arguments:(`Assoc [])
  in
  Alcotest.(check bool) "missing room_id fails" false ok_missing;
  Alcotest.(check bool)
    "missing room_id message"
    true
    (contains_substring msg_missing "room_id is required");

  let (ok_out_of_range, msg_out_of_range) =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_trpg_dice_roll"
      ~arguments:
        (`Assoc
          [
            ("room_id", `String "room-mcp-e2e");
            ("actor_id", `String "pc-1");
            ("action", `String "perception");
            ("stat_value", `Int 12);
            ("dc", `Int 10);
            ("raw_d20", `Int 21);
          ])
  in
  Alcotest.(check bool) "raw_d20 out-of-range fails" false ok_out_of_range;
  Alcotest.(check bool)
    "raw_d20 out-of-range message"
    true
    (contains_substring msg_out_of_range "raw_d20 must be between 1 and 20");

  let (ok_bad_event_type, msg_bad_event_type) =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_trpg_stream"
      ~arguments:
        (`Assoc
          [
            ("room_id", `String "room-mcp-e2e");
            ("event_type", `String "totally.invalid");
          ])
  in
  Alcotest.(check bool) "invalid event_type fails" false ok_bad_event_type;
  Alcotest.(check bool)
    "invalid event_type message"
    true
    (contains_substring msg_bad_event_type "invalid event_type");

  cleanup_dir base_path

let test_execute_tool_explicit_agent_name_not_overridden () =
  Eio_main.run @@ fun env ->
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-explicit-agent-name-regression" in

  let (ok_init, _init_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_init"
      ~arguments:(`Assoc [])
  in
  Alcotest.(check bool) "init success" true ok_init;

  let (ok_join_codex, join_codex_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_join"
      ~arguments:(`Assoc [("agent_name", `String "codex")])
  in
  Alcotest.(check bool) "join codex success" true ok_join_codex;
  Alcotest.(check bool)
    "join codex type"
    true
    (contains_substring join_codex_msg "Type: codex");

  let (ok_join_gemini, join_gemini_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_join"
      ~arguments:(`Assoc [("agent_name", `String "gemini")])
  in
  Alcotest.(check bool) "join gemini success" true ok_join_gemini;
  Alcotest.(check bool)
    "explicit agent_name should win over persisted nickname"
    true
    (contains_substring join_gemini_msg "Type: gemini");

  cleanup_dir base_path

let test_execute_tool_explicit_alias_reuses_joined_nickname () =
  Eio_main.run @@ fun env ->
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-explicit-alias-reuse-regression" in

  let (ok_init, _init_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_init"
      ~arguments:(`Assoc [])
  in
  Alcotest.(check bool) "init success" true ok_init;

  let _added =
    Masc_mcp.Room.add_task state.room_config
      ~title:"alias-reuse-task"
      ~priority:2
      ~description:""
  in

  let transition action =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_transition"
      ~arguments:(`Assoc [
        ("task_id", `String "task-001");
        ("action", `String action);
        ("agent_name", `String "alpha-agent");
      ])
  in

  let (ok_claim, claim_msg) = transition "claim" in
  Alcotest.(check bool) "claim success" true ok_claim;
  Alcotest.(check bool) "claim message has claimed" true (contains_substring claim_msg "claimed");

  let (ok_start, start_msg) = transition "start" in
  Alcotest.(check bool) "start success with same explicit alias" true ok_start;
  Alcotest.(check bool) "start message has in_progress" true (contains_substring start_msg "in_progress");

  let (ok_done, done_msg) = transition "done" in
  Alcotest.(check bool) "done success with same explicit alias" true ok_done;
  Alcotest.(check bool) "done message has done" true (contains_substring done_msg "done");

  cleanup_dir base_path

let test_handle_request_tools_call_trpg () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 9);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_trpg_dice_roll");
      ("arguments", `Assoc [
        ("room_id", `String "room-mcp-call");
        ("actor_id", `String "pc-1");
        ("action", `String "perception");
        ("stat_value", `Int 9);
        ("dc", `Int 8);
        ("raw_d20", `Int 12);
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in
  (match response with
  | `Assoc fields ->
      Alcotest.(check bool) "has result" true (List.mem_assoc "result" fields)
  | _ -> Alcotest.fail "response not an object");

  cleanup_dir base_path

let test_handle_request_invalid_json () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let response = Mcp_eio.handle_request ~clock ~sw state "not valid json {{{" in

  (match response with
   | `Assoc fields ->
       Alcotest.(check bool) "has error" true (List.mem_assoc "error" fields)
   | _ -> Alcotest.fail "response not an object");

  cleanup_dir base_path

let test_handle_request_method_not_found () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 99);
    ("method", `String "unknown/method");
    ("params", `Assoc []);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in

  (match response with
   | `Assoc fields ->
       Alcotest.(check bool) "has error" true (List.mem_assoc "error" fields);
       (match List.assoc_opt "error" fields with
        | Some (`Assoc error_fields) ->
            let code = List.assoc "code" error_fields in
            Alcotest.(check bool) "error code -32601" true (code = `Int (-32601))
        | _ -> Alcotest.fail "error not an object")
   | _ -> Alcotest.fail "response not an object");

  cleanup_dir base_path

(* ===== Test Suites ===== *)

let state_tests = [
  "create_state", `Quick, test_create_state;
  "type compatibility", `Quick, test_type_compatibility;
]

let protocol_tests = [
  "is_jsonrpc_v2", `Quick, test_is_jsonrpc_v2;
  "jsonrpc_request parsing", `Quick, test_jsonrpc_request_parsing;
  "is_notification", `Quick, test_is_notification;
  "protocol version", `Quick, test_protocol_version;
]

let response_tests = [
  "make_response", `Quick, test_make_response;
  "make_error", `Quick, test_make_error;
]

let eio_tests = [
  "handle initialize", `Quick, test_handle_request_initialize;
  "handle tools/list", `Quick, test_handle_request_tools_list;
  "handle invalid json", `Quick, test_handle_request_invalid_json;
  "handle method not found", `Quick, test_handle_request_method_not_found;
  "handle tools/call trpg", `Quick, test_handle_request_tools_call_trpg;
  "execute trpg flow", `Quick, test_execute_tool_trpg_flow;
  "execute trpg validation", `Quick, test_execute_tool_trpg_validation;
  "explicit agent_name not overridden", `Quick, test_execute_tool_explicit_agent_name_not_overridden;
  "explicit alias reuses joined nickname", `Quick, test_execute_tool_explicit_alias_reuses_joined_nickname;
]

let () =
  Alcotest.run "Mcp_server_eio" [
    "state", state_tests;
    "protocol", protocol_tests;
    "response", response_tests;
    "eio", eio_tests;
  ]
