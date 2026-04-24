(** Test suite for Mcp_server_eio module

    Tests the Eio-native MCP server implementation.
    Uses Eio_main.run for async test context.
*)

module Mcp_eio = Masc_mcp.Mcp_server_eio
module Mcp = Masc_mcp.Mcp_server
module Config = Masc_mcp.Config
module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_result = Masc_mcp.Tool_result
module Keeper_types = Masc_mcp.Keeper_types
module Keeper_registry = Masc_mcp.Keeper_registry
module Masc_log = Log

let () = Mirage_crypto_rng_unix.use_default ()

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

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let write_text_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let make_keeper_meta ?agent_name name =
  let agent_name =
    Option.value agent_name
      ~default:(Keeper_types.keeper_agent_name name)
  in
  let json =
    `Assoc
      [
        ("name", `String name);
        ("agent_name", `String agent_name);
        ("trace_id", `String ("trace-test-" ^ name));
        ("goal", `String "test goal");
      ]
  in
  match Keeper_types.meta_of_json json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_keeper_meta failed: " ^ err)

let extract_json_from_text text =
  try
    let idx = String.index text '{' in
    Yojson.Safe.from_string (String.sub text idx (String.length text - idx))
  with Not_found ->
    Alcotest.failf "expected JSON payload in text: %s" text

let tools_list_response ~clock ~sw ?profile ?cursor state =
  let params =
    match cursor with
    | Some cursor -> `Assoc [ ("cursor", `String cursor) ]
    | None -> `Assoc []
  in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 2);
          ("method", `String "tools/list");
          ("params", params);
        ])
  in
  match profile with
  | Some profile -> Mcp_eio.handle_request ~clock ~sw ~profile state request
  | None -> Mcp_eio.handle_request ~clock ~sw state request

let tools_from_response response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | Some (`Assoc result_fields) -> (
          match List.assoc_opt "tools" result_fields with
          | Some (`List tools) -> tools
          | _ -> Alcotest.fail "tools not a list")
      | _ -> Alcotest.fail "result not an object")
  | _ -> Alcotest.fail "response not an object"

let result_fields_exn response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | Some (`Assoc result_fields) -> result_fields
      | _ -> Alcotest.fail "result not an object")
  | _ -> Alcotest.fail "response not an object"

let next_cursor_of_response response =
  match List.assoc_opt "nextCursor" (result_fields_exn response) with
  | Some (`String cursor) -> Some cursor
  | Some _ -> Alcotest.fail "nextCursor not a string"
  | None -> None

let tools_list_meta_exn response =
  match List.assoc_opt "_meta" (result_fields_exn response) with
  | Some (`Assoc fields) -> fields
  | _ -> Alcotest.fail "_meta not an object"

let int_field_exn label fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> value
  | _ -> Alcotest.failf "%s missing int field %s" label name

let latest_log_seq () =
  match Masc_log.Ring.recent ~limit:1 () with
  | (entry : Masc_log.Ring.entry) :: _ -> entry.seq
  | [] -> -1

let json_string_field_exn label json field =
  match Yojson.Safe.Util.(json |> member field |> to_string_option) with
  | Some value -> value
  | None ->
      Alcotest.failf "%s missing string field %s: %s" label field
        (Yojson.Safe.to_string json)

let log_detail_string (entry : Masc_log.Ring.entry) field =
  Yojson.Safe.Util.(entry.details |> member field |> to_string_option)

let find_mcp_tool_log_exn ~phase ~tool_name ~request_id entries =
  match
    List.find_opt
      (fun entry ->
        Option.equal String.equal (log_detail_string entry "phase") (Some phase)
        && Option.equal String.equal
             (log_detail_string entry "tool_name")
             (Some tool_name)
        && Option.equal String.equal
             (log_detail_string entry "request_id")
             (Some request_id))
      entries
  with
  | Some entry -> entry
  | None ->
      Alcotest.failf "MCP tool log missing phase=%s tool=%s request_id=%s"
        phase tool_name request_id

let test_resolve_join_state_skips_read_only_lookup () =
  let called = ref false in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:false
      ~agent_name:"codex"
      ~check_join:(fun () ->
        called := true;
        true)
  in
  Alcotest.(check bool) "lookup skipped" false !called;
  Alcotest.(check bool) "read-only defaults false" false joined

let test_resolve_join_state_checks_join_required_tools () =
  let called = ref false in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"codex"
      ~check_join:(fun () ->
        called := true;
        true)
  in
  Alcotest.(check bool) "lookup performed" true !called;
  Alcotest.(check bool) "join result preserved" true joined

let test_resolve_join_state_skips_unknown_agent () =
  let called = ref false in
  let joined =
    Masc_mcp.Mcp_server_eio_execute.resolve_join_state
      ~room_initialized:true
      ~join_required:true
      ~agent_name:"unknown"
      ~check_join:(fun () ->
        called := true;
        true)
  in
  Alcotest.(check bool) "unknown agent skipped" false !called;
  Alcotest.(check bool) "unknown agent treated unjoined" false joined

let test_should_read_legacy_persisted_agent_name () =
  let should_read =
    Masc_mcp.Mcp_server_eio_execute.should_read_legacy_persisted_agent_name
  in
  Alcotest.(check bool) "ephemeral fallback reads legacy state" true
    (should_read ~has_explicit_agent_name:false ~agent_name:"agent-12345678");
  Alcotest.(check bool) "stable nickname skips legacy read" false
    (should_read ~has_explicit_agent_name:false
       ~agent_name:"codex-swift-fox");
  Alcotest.(check bool) "explicit agent name skips legacy read" false
    (should_read ~has_explicit_agent_name:true ~agent_name:"agent-12345678")

let rec collect_tools ~clock ~sw ?profile ?cursor state acc =
  let response = tools_list_response ~clock ~sw ?profile ?cursor state in
  let tools = tools_from_response response in
  match next_cursor_of_response response with
  | Some next -> collect_tools ~clock ~sw ?profile ~cursor:next state (acc @ tools)
  | None -> acc @ tools

let tools_list_all ~clock ~sw ?profile state =
  collect_tools ~clock ~sw ?profile state []

let resources_list_response ~clock ~sw ?cursor state =
  let params =
    match cursor with
    | Some cursor -> `Assoc [ ("cursor", `String cursor) ]
    | None -> `Assoc []
  in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 23);
          ("method", `String "resources/list");
          ("params", params);
        ])
  in
  Mcp_eio.handle_request ~clock ~sw state request

let resources_from_response response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | Some (`Assoc result_fields) -> (
          match List.assoc_opt "resources" result_fields with
          | Some (`List resources) -> resources
          | _ -> Alcotest.fail "resources not a list")
      | _ -> Alcotest.fail "result not an object")
  | _ -> Alcotest.fail "response not an object"

let rec resources_list_all ~clock ~sw ?cursor state acc =
  let response = resources_list_response ~clock ~sw ?cursor state in
  let resources = resources_from_response response in
  match next_cursor_of_response response with
  | Some next -> resources_list_all ~clock ~sw ~cursor:next state (acc @ resources)
  | None -> acc @ resources
let find_tool_exn tools name =
  match
    List.find_map
      (function
        | `Assoc fields as tool -> (
            match List.assoc_opt "name" fields with
            | Some (`String n) when String.equal n name -> Some tool
            | _ -> None)
        | _ -> None)
      tools
  with
  | Some tool -> tool
  | None -> Alcotest.failf "tool missing: %s" name

let tool_string_field tool field =
  match tool with
  | `Assoc fields -> (
      match List.assoc_opt field fields with
      | Some (`String value) -> value
      | _ -> Alcotest.failf "tool field missing: %s" field)
  | _ -> Alcotest.fail "tool is not an object"

let result_envelope_exn response =
  match List.assoc_opt "resultEnvelope" (result_fields_exn response) with
  | Some (`Assoc fields) -> fields
  | _ -> Alcotest.fail "resultEnvelope missing"

let structured_content_exn response =
  match List.assoc_opt "structuredContent" (result_fields_exn response) with
  | Some json -> json
  | None -> Alcotest.fail "structuredContent missing"

let workflow_next_step_names response =
  match List.assoc_opt "workflow_guidance" (result_envelope_exn response) with
  | Some (`Assoc fields) -> (
      match List.assoc_opt "next_steps" fields with
      | Some (`List steps) ->
          steps
          |> List.filter_map (function
               | `Assoc step_fields -> List.assoc_opt "tool" step_fields
               | _ -> None)
          |> List.filter_map (function `String value -> Some value | _ -> None)
      | _ -> [])
  | Some `Null | None -> []
  | _ -> Alcotest.fail "workflow_guidance malformed"

let error_code_exn response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`Assoc error_fields) -> (
          match List.assoc_opt "code" error_fields with
          | Some (`Int value) -> value
          | _ -> Alcotest.fail "error code missing")
      | _ -> Alcotest.fail "error object missing")
  | _ -> Alcotest.fail "response not an object"

let error_message_exn response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`Assoc error_fields) -> (
          match List.assoc_opt "message" error_fields with
          | Some (`String value) -> value
          | _ -> Alcotest.fail "error message missing")
      | _ -> Alcotest.fail "error object missing")
  | _ -> Alcotest.fail "response not an object"

let resource_content_exn response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | Some (`Assoc result_fields) -> (
          match List.assoc_opt "contents" result_fields with
          | Some (`List (`Assoc content_fields :: _)) -> content_fields
          | _ -> Alcotest.fail "resource contents missing")
      | _ -> Alcotest.fail "result not an object")
  | _ -> Alcotest.fail "response not an object"

let resource_text_exn response =
  match List.assoc_opt "text" (resource_content_exn response) with
  | Some (`String value) -> value
  | _ -> Alcotest.fail "resource text missing"

let resource_mime_type_exn response =
  match List.assoc_opt "mimeType" (resource_content_exn response) with
  | Some (`String value) -> value
  | _ -> Alcotest.fail "resource mime type missing"

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
  let state2 : Mcp.server_state = state in  (* Type unification at compile time *)
  (* Verify the unified type preserves field access *)
  Alcotest.(check string) "base_path via unified type" base_path state2.room_config.base_path;
  cleanup_dir base_path

let test_eio_context_delegation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  let delegated_net = Eio_context.get_net_opt () in
  let alias_clock = Mcp_eio.get_clock () in
  Alcotest.(check bool) "net delegated to shared Eio_context" true
    (Option.is_some delegated_net);
  Alcotest.(check bool) "clock delegated to shared Eio_context" true
    (Eio_context.get_clock () == alias_clock)

let option_ref_equal left right =
  match left, right with
  | None, None -> true
  | Some l, Some r -> l == r
  | None, Some _ | Some _, None -> false

let test_eio_context_with_test_env_restores () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  let before_net = Eio_context.get_net_opt () in
  let before_clock = Eio_context.get_clock_opt () in
  let before_mono_clock = Eio_context.get_mono_clock_opt () in
  let before_switch = Eio_context.get_switch_opt () in
  Eio.Switch.run @@ fun sw ->
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    Alcotest.(check bool) "scoped net set" true
      (Option.is_some (Eio_context.get_net_opt ()));
    Alcotest.(check bool) "scoped clock set" true
      (Option.is_some (Eio_context.get_clock_opt ()));
    Alcotest.(check bool) "scoped mono_clock set" true
      (Option.is_some (Eio_context.get_mono_clock_opt ()));
    Alcotest.(check bool) "scoped switch set" true
      (Option.is_some (Eio_context.get_switch_opt ())));
  Alcotest.(check bool) "net restored" true
    (option_ref_equal before_net (Eio_context.get_net_opt ()));
  Alcotest.(check bool) "clock restored" true
    (option_ref_equal before_clock (Eio_context.get_clock_opt ()));
  Alcotest.(check bool) "mono_clock restored" true
    (option_ref_equal before_mono_clock (Eio_context.get_mono_clock_opt ()));
  Alcotest.(check bool) "switch restored" true
    (option_ref_equal before_switch (Eio_context.get_switch_opt ()))

(* ===== Unit Tests for Protocol Helpers ===== *)

let test_is_jsonrpc_v2 () =
  let valid = `Assoc [("jsonrpc", `String "2.0"); ("method", `String "test")] in
  let invalid = `Assoc [("jsonrpc", `String "1.0")] in
  let no_version = `Assoc [("method", `String "test")] in
  Alcotest.(check bool) "valid 2.0" true (Masc_mcp.Mcp_server.is_jsonrpc_v2 valid);
  Alcotest.(check bool) "invalid 1.0" false (Masc_mcp.Mcp_server.is_jsonrpc_v2 invalid);
  Alcotest.(check bool) "no version" false (Masc_mcp.Mcp_server.is_jsonrpc_v2 no_version)

let test_jsonrpc_request_parsing () =
  let json = `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "initialize");
    ("params", `Assoc []);
  ] in
  match Masc_mcp.Mcp_server.jsonrpc_request_of_yojson json with
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
  (match Masc_mcp.Mcp_server.jsonrpc_request_of_yojson with_id with
   | Ok req -> Alcotest.(check bool) "with id" false (Masc_mcp.Mcp_server.is_notification req)
   | Error _ -> Alcotest.fail "parse error");
  (match Masc_mcp.Mcp_server.jsonrpc_request_of_yojson without_id with
   | Ok req -> Alcotest.(check bool) "without id" true (Masc_mcp.Mcp_server.is_notification req)
   | Error _ -> Alcotest.fail "parse error")

let test_protocol_version () =
  let params = Some (`Assoc [("protocolVersion", `String "2025-06-18")]) in
  let version = Masc_mcp.Mcp_server.protocol_version_from_params params in
  Alcotest.(check string) "version extracted" "2025-06-18" version;

  (match Mcp.validate_protocol_version "2025-06-18" with
   | Ok version ->
       Alcotest.(check string) "2025-06-18 is supported" "2025-06-18" version
   | Error msg -> Alcotest.fail msg);

  let normalized = Masc_mcp.Mcp_server.normalize_protocol_version "unknown" in
  Alcotest.(check string) "normalized to default" "2025-11-25" normalized;

  match Mcp.validate_protocol_version "unknown" with
  | Error msg ->
      Alcotest.(check bool) "unsupported version rejected" true
        (contains_substring msg "Unsupported protocolVersion")
  | Ok _ -> Alcotest.fail "expected unsupported protocol version to be rejected"

(* ===== Unit Tests for Response Builders ===== *)

let test_make_response () =
  let response = Masc_mcp.Mcp_server.make_response ~id:(`Int 42) (`String "result") in
  match response with
  | `Assoc fields ->
      let id = List.assoc "id" fields in
      let result = List.assoc "result" fields in
      Alcotest.(check bool) "has jsonrpc" true (List.mem_assoc "jsonrpc" fields);
      Alcotest.(check bool) "id is 42" true (id = `Int 42);
      Alcotest.(check bool) "result is string" true (result = `String "result")
  | _ -> Alcotest.fail "not an object"

let test_make_error () =
  let response = Masc_mcp.Mcp_server.make_error ~id:(`Int 1) (-32600) "Invalid Request" in
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
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "initialize");
    ("params", `Assoc [
      ("protocolVersion", `String "2025-06-18");
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
            Alcotest.(check (option string)) "echoes requested protocol version"
              (Some "2025-06-18")
              (match List.assoc_opt "protocolVersion" result_fields with
               | Some (`String version) -> Some version
               | _ -> None);
            Alcotest.(check bool) "has serverInfo" true
              (List.mem_assoc "serverInfo" result_fields);
            Alcotest.(check bool) "has capabilities" true
              (List.mem_assoc "capabilities" result_fields)
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");

  cleanup_dir base_path

let test_handle_request_initialize_rejects_unsupported_protocol_version () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 101);
    ("method", `String "initialize");
    ("params", `Assoc [
      ("protocolVersion", `String "2099-01-01");
      ("capabilities", `Assoc []);
      ("clientInfo", `Assoc [
        ("name", `String "test");
        ("version", `String "1.0");
      ]);
    ]);
  ]) in

  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check bool) "unsupported protocol message" true
    (contains_substring (error_message_exn response) "Unsupported protocolVersion");

  cleanup_dir base_path

let test_handle_request_tools_list () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let first_page = tools_list_response ~clock ~sw state in

  let tools = tools_list_all ~clock ~sw state in

  let names =
    tools
    |> List.filter_map (function
         | `Assoc fields -> List.assoc_opt "name" fields
         | _ -> None)
    |> List.filter_map (function `String s -> Some s | _ -> None)
  in
  (* Public MCP surface: only allowlisted tools are visible. *)
  Alcotest.(check bool)
    "contains masc_status (public surface)"
    true
    (List.mem "masc_status" names);
  Alcotest.(check bool)
    "contains masc_board_post (public surface)"
    true
    (List.mem "masc_board_post" names);
  Alcotest.(check bool)
    "omits masc_voice_agent (public surface)"
    false
    (List.mem "masc_voice_agent" names);
  Alcotest.(check bool)
    "omits masc_voice_speak (public surface)"
    false
    (List.mem "masc_voice_speak" names);
  Alcotest.(check bool)
    "omits masc_voice_ping_pong (public surface)"
    false
    (List.mem "masc_voice_ping_pong" names);
  Alcotest.(check bool)
    "board_search hidden from public surface"
    false
    (List.mem "masc_board_search" names);
  Alcotest.(check bool)
    "legacy experiment_start hidden from list"
    false
    (List.mem "experiment_start" names);
  Alcotest.(check bool)
    "named room list hidden from list"
    false
    (List.mem "masc_rooms_list" names);
  Alcotest.(check bool)
    "named room create hidden from list"
    false
    (List.mem "masc_room_create" names);
  Alcotest.(check bool)
    "named room enter hidden from list"
    false
    (List.mem "masc_room_enter" names);
  Alcotest.(check bool)
    "removed ghost tool absent from list"
    false
    (List.mem "masc_post_create" names);
  Alcotest.(check bool) "first page non-empty" true (names <> []);
  let meta = tools_list_meta_exn first_page in
  let total_count = int_field_exn "tools/list _meta" meta "totalCount" in
  let page_size = int_field_exn "tools/list _meta" meta "pageSize" in
  Alcotest.(check bool) "next cursor matches totalCount/pageSize"
    (total_count > page_size)
    (Option.is_some (next_cursor_of_response first_page));

  cleanup_dir base_path

let test_handle_request_initialize_operator_profile () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 11);
    ("method", `String "initialize");
    ("params", `Assoc [
      ("protocolVersion", `String "2025-11-25");
      ("capabilities", `Assoc []);
      ("clientInfo", `Assoc [
        ("name", `String "remote-operator");
        ("version", `String "1.0");
      ]);
    ]);
  ]) in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~profile:Mcp_eio.Operator_remote state request
  in
  (match response with
   | `Assoc fields ->
       (match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) ->
            let instructions =
              match List.assoc_opt "instructions" result_fields with
              | Some (`String value) -> value
              | _ -> ""
            in
            Alcotest.(check bool) "mentions operator profile" true
              (contains_substring instructions "four control-plane tools");
            Alcotest.(check bool) "mentions confirm workflow" true
              (contains_substring instructions "confirm_required=true")
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_tools_list_operator_profile () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 12);
    ("method", `String "tools/list");
    ("params", `Assoc []);
  ]) in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~profile:Mcp_eio.Operator_remote state request
  in
  (match response with
   | `Assoc fields ->
       (match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) ->
            (match List.assoc_opt "tools" result_fields with
             | Some (`List tools) ->
                 let names =
                   tools
                   |> List.filter_map (function
                        | `Assoc fields -> List.assoc_opt "name" fields
                        | _ -> None)
                   |> List.filter_map (function `String s -> Some s | _ -> None)
                 in
                 Alcotest.(check (list string)) "operator-only tools"
                   [
                     "masc_operator_action";
                     "masc_operator_confirm";
                     "masc_operator_digest";
                     "masc_operator_snapshot";
                     "masc_surface_audit";
                   ]
                   names;
                 let find_tool name =
                   List.find_map
                     (function
                       | `Assoc fields as tool -> (
                           match List.assoc_opt "name" fields with
                           | Some (`String n) when String.equal n name -> Some tool
                           | _ -> None)
                       | _ -> None)
                     tools
                 in
                 let snapshot_tool =
                   match find_tool "masc_operator_snapshot" with
                   | Some tool -> tool
                   | None -> Alcotest.fail "snapshot tool missing"
                 in
                 let action_tool =
                   match find_tool "masc_operator_action" with
                   | Some tool -> tool
                   | None -> Alcotest.fail "action tool missing"
                 in
                 let digest_tool =
                   match find_tool "masc_operator_digest" with
                   | Some tool -> tool
                   | None -> Alcotest.fail "digest tool missing"
                 in
                 Alcotest.(check bool) "snapshot has title" true
                   (Yojson.Safe.Util.member "title" snapshot_tool <> `Null);
                 Alcotest.(check bool) "snapshot has icons" true
                   (Yojson.Safe.Util.member "icons" snapshot_tool <> `Null);
                 Alcotest.(check bool) "snapshot readonly hint" true
                   (snapshot_tool |> Yojson.Safe.Util.member "annotations"
                    |> Yojson.Safe.Util.member "readOnlyHint"
                    |> Yojson.Safe.Util.to_bool);
                 Alcotest.(check bool) "digest readonly hint" true
                   (digest_tool |> Yojson.Safe.Util.member "annotations"
                    |> Yojson.Safe.Util.member "readOnlyHint"
                    |> Yojson.Safe.Util.to_bool);
                 Alcotest.(check bool) "action readonly hint" false
                   (action_tool |> Yojson.Safe.Util.member "annotations"
                    |> Yojson.Safe.Util.member "readOnlyHint"
                    |> Yojson.Safe.Util.to_bool);
                 (* #7480 Step 1: read-only tools advertise
                    openWorldHint=false so MCP clients know they do not
                    reach outside MASC's own state. *)
                 Alcotest.(check bool) "snapshot openWorld=false" false
                   (snapshot_tool |> Yojson.Safe.Util.member "annotations"
                    |> Yojson.Safe.Util.member "openWorldHint"
                    |> Yojson.Safe.Util.to_bool);
                 Alcotest.(check bool) "digest openWorld=false" false
                   (digest_tool |> Yojson.Safe.Util.member "annotations"
                    |> Yojson.Safe.Util.member "openWorldHint"
                    |> Yojson.Safe.Util.to_bool)
             | _ -> Alcotest.fail "tools not a list")
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_initialize_managed_profile () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 111);
    ("method", `String "initialize");
    ("params", `Assoc [
      ("protocolVersion", `String "2025-11-25");
      ("capabilities", `Assoc []);
      ("clientInfo", `Assoc [
        ("name", `String "managed-agent");
        ("version", `String "1.0");
      ]);
    ]);
  ]) in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~profile:Mcp_eio.Managed_agent state request
  in
  (match response with
   | `Assoc fields ->
       (match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) ->
            let instructions =
              match List.assoc_opt "instructions" result_fields with
              | Some (`String value) -> value
              | _ -> ""
            in
            Alcotest.(check bool) "mentions managed profile" true
              (contains_substring instructions "managed-agent profile");
            Alcotest.(check bool) "mentions canonical task control" true
              (contains_substring instructions "masc_transition")
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_tools_list_managed_profile () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 112);
    ("method", `String "tools/list");
    ("params", `Assoc []);
  ]) in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~profile:Mcp_eio.Managed_agent state request
  in
  (match response with
   | `Assoc fields ->
       (match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) ->
            (match List.assoc_opt "tools" result_fields with
             | Some (`List tools) ->
                 let names =
                   tools
                   |> List.filter_map (function
                        | `Assoc fields -> List.assoc_opt "name" fields
                        | _ -> None)
                   |> List.filter_map (function `String s -> Some s | _ -> None)
                 in
                 Alcotest.(check bool) "has managed room status alias" true
                   (List.mem "masc_room_status" names);
                 Alcotest.(check bool) "has managed list tasks alias" true
                   (List.mem "masc_list_tasks" names);
                 Alcotest.(check bool) "hides managed claim alias" false
                   (List.mem "masc_claim_task" names);
                 Alcotest.(check bool) "omits raw masc_status" false
                   (List.mem "masc_status" names);
                 Alcotest.(check bool) "omits raw masc_transition" false
                   (List.mem "masc_transition" names);
                 Alcotest.(check bool) "omits managed voice agent" false
                   (List.mem "masc_voice_agent" names);
                 Alcotest.(check bool) "omits managed voice speak" false
                   (List.mem "masc_voice_speak" names);
                 Alcotest.(check bool) "omits managed voice ping pong" false
                   (List.mem "masc_voice_ping_pong" names)
             | _ -> Alcotest.fail "tools not a list")
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_tools_call_managed_profile_sdk_alias_claim () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-managed-alias-claim" in
  let (ok_init, _init_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_init" ~arguments:(`Assoc [])
  in
  (* masc_init pruned from registry — dispatch fails. Initialise the
     room state directly so downstream masc_join succeeds. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
  let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in
  let (ok_join, _join_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_join"
      ~arguments:(`Assoc [ ("agent_name", `String "codex") ])
  in
  Alcotest.(check bool) "join success" true ok_join;
  let _added =
    Masc_mcp.Coord.add_task state.room_config ~title:"managed-claim"
      ~priority:2 ~description:""
  in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 113);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_claim_task");
      ("arguments", `Assoc [ ("task_id", `String "task-001") ]);
    ]);
  ]) in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~profile:Mcp_eio.Managed_agent
      ~mcp_session_id:sid state request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "claim response mentions task" true
    (contains_substring response_text "task-001");
  Alcotest.(check bool) "claim response mentions claimed" true
    (contains_substring response_text "claimed");
  cleanup_dir base_path

let test_handle_request_tools_call_transition_claim_guidance () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-transition-claim-guidance" in
  let (ok_init, _) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_init" ~arguments:(`Assoc [])
  in
  (* masc_init pruned from registry — dispatch fails. Initialise the
     room state directly so downstream masc_join succeeds. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
  let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in
  let (ok_join, _) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_join"
      ~arguments:(`Assoc [ ("agent_name", `String "codex") ])
  in
  Alcotest.(check bool) "join success" true ok_join;
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"transition-claim"
       ~priority:2 ~description:"");
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 114);
          ("method", `String "tools/call");
          ( "params",
            `Assoc
              [
                ("name", `String "masc_transition");
                ( "arguments",
                  `Assoc
                    [
                      ("task_id", `String "task-001");
                      ("action", `String "claim");
                    ] );
              ] );
        ])
  in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:sid state request
  in
  let steps = workflow_next_step_names response in
  Alcotest.(check (option string)) "claim binds current_task" (Some "task-001")
    (Masc_mcp.Planning_eio.get_current_task state.room_config);
  Alcotest.(check bool) "claim guidance omits plan_set_task" false
    (List.mem "masc_plan_set_task" steps);
  cleanup_dir base_path

let test_handle_request_tools_call_transition_done_guidance () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-transition-done-guidance" in
  let (ok_init, _) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_init" ~arguments:(`Assoc [])
  in
  (* masc_init pruned from registry — dispatch fails. Initialise the
     room state directly so downstream masc_join succeeds. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
  let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in
  let (ok_join, _) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_join"
      ~arguments:(`Assoc [ ("agent_name", `String "codex") ])
  in
  Alcotest.(check bool) "join success" true ok_join;
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"transition-done"
       ~priority:2 ~description:"");
  let (ok_claim, _) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_transition"
      ~arguments:
        (`Assoc
          [
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
  in
  Alcotest.(check bool) "claim setup success" true ok_claim;
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 115);
          ("method", `String "tools/call");
          ( "params",
            `Assoc
              [
                ("name", `String "masc_transition");
                ( "arguments",
                  `Assoc
                    [
                      ("task_id", `String "task-001");
                      ("action", `String "done");
                      ("notes", `String "Completed task and verified output");
                    ] );
              ] );
        ])
  in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:sid state request
  in
  let steps = workflow_next_step_names response in
  Alcotest.(check bool) "done guidance includes status" true
    (List.mem "masc_status" steps);
  Alcotest.(check bool) "done guidance omits plan_set_task" false
    (List.mem "masc_plan_set_task" steps);
  cleanup_dir base_path

let test_handle_request_tools_call_transition_claim_requires_action () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-deprecated-claim-alias" in
  let (ok_init, _) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_init" ~arguments:(`Assoc [])
  in
  (* masc_init pruned from registry — dispatch fails. Initialise the
     room state directly so downstream masc_join succeeds. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
  let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in
  let (ok_join, _) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_join"
      ~arguments:(`Assoc [ ("agent_name", `String "codex") ])
  in
  Alcotest.(check bool) "join success" true ok_join;
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"deprecated-claim"
       ~priority:2 ~description:"");
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 116);
          ("method", `String "tools/call");
          ( "params",
            `Assoc
              [
                ("name", `String "masc_transition");
                ("arguments", `Assoc [ ("task_id", `String "task-001") ]);
              ] );
        ])
  in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:sid state request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "missing action rejected" true
    (contains_substring response_text "action is required");
  cleanup_dir base_path

let test_handle_request_tools_call_operator_profile_rejects_non_operator () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 13);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_status");
      ("arguments", `Assoc []);
    ]);
  ]) in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~profile:Mcp_eio.Operator_remote state request
  in
  (match response with
   | `Assoc fields ->
       (match List.assoc_opt "error" fields with
        | Some (`Assoc error_fields) ->
            Alcotest.(check bool) "method not available" true
              (match List.assoc_opt "message" error_fields with
               | Some (`String msg) ->
                   contains_substring msg "not available on this MCP endpoint"
               | _ -> false)
        | _ -> Alcotest.fail "error missing")
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_tools_list_rejects_nonstandard_names_filter () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 120);
    ("method", `String "tools/list");
    ("params", `Assoc [
      ("names", `List [ `String "masc_messages"; `String "masc_status" ]);
    ]);
  ]) in
  let response =
    Mcp_eio.handle_request ~clock ~sw state request
  in
  let tools = tools_from_response response in
  let names =
    tools
    |> List.filter_map (function
         | `Assoc fields -> List.assoc_opt "name" fields
         | _ -> None)
    |> List.filter_map (function `String s -> Some s | _ -> None)
  in
  Alcotest.(check (list string)) "requested tools only"
    [ "masc_messages"; "masc_status" ] names;
  cleanup_dir base_path

let test_handle_request_tools_list_with_placeholder_flag () =
  with_env "MASC_PLACEHOLDER_TOOLS_ENABLED" "1" (fun () ->
    Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
    let clock = Eio.Stdenv.clock env in
    Eio.Switch.run @@ fun sw ->

    let base_path = temp_dir () in
    let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
    let tools = tools_list_all ~clock ~sw state in
    let names =
      tools
      |> List.filter_map (function
           | `Assoc fields -> List.assoc_opt "name" fields
           | _ -> None)
      |> List.filter_map (function `String s -> Some s | _ -> None)
    in
    Alcotest.(check bool)
      "placeholder tool removed even with flag"
      false
      (List.mem "masc_archive_save" names);

    cleanup_dir base_path)

let test_handle_request_tools_list_include_hidden_metadata () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let tools = tools_list_all ~clock ~sw state in
  let status_tool = find_tool_exn tools "masc_status" in
  Alcotest.(check bool) "standard tools expose title" true
    (tool_string_field status_tool "title" <> "");
  Alcotest.(check bool) "standard tools expose icons" true
    (Yojson.Safe.Util.member "icons" status_tool <> `Null);
  Alcotest.(check bool) "standard tools expose annotations" true
    (Yojson.Safe.Util.member "annotations" status_tool <> `Null);
  Alcotest.(check bool) "standard tools do not advertise outputSchema prematurely"
    true
    (Yojson.Safe.Util.member "outputSchema" status_tool = `Null);
  Alcotest.(check bool) "visibility metadata exposed" true
    (Yojson.Safe.Util.member "visibility" status_tool <> `Null);
  Alcotest.(check bool) "implementation status exposed" true
    (Yojson.Safe.Util.member "implementationStatus" status_tool <> `Null);
  Alcotest.(check bool) "removed ghost tool absent" false
    (List.exists
       (function
         | `Assoc fields -> List.assoc_opt "name" fields = Some (`String "masc_post_create")
         | _ -> false)
       tools);

  cleanup_dir base_path

let test_handle_request_tools_list_include_deprecated_claim_alias_metadata () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 219);
          ("method", `String "tools/list");
          ( "params",
            `Assoc
              [
                ("include_deprecated", `Bool true);
                ("names", `List [ `String "masc_transition" ]);
              ] );
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let tools = tools_from_response response in
  let transition_tool = find_tool_exn tools "masc_transition" in
  Alcotest.(check string) "transition lifecycle remains active" "active"
    (tool_string_field transition_tool "lifecycle");
  (match transition_tool with
   | `Assoc fields ->
       Alcotest.(check bool) "transition omits canonical alias metadata" false
         (List.mem_assoc "canonicalName" fields);
       Alcotest.(check bool) "transition omits replacement alias metadata" false
         (List.mem_assoc "replacement" fields)
   | _ -> Alcotest.fail "tool is not an object");
  cleanup_dir base_path

let _test_handle_request_tools_list_hides_internal_tool_by_default () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let tools = tools_list_all ~clock ~sw state in
  Alcotest.(check bool) "internal tool hidden from public surface" false
    (List.exists
       (function
         | `Assoc fields -> (
             match List.assoc_opt "name" fields with
             | Some (`String "masc_code_search") -> true
             | _ -> false)
         | _ -> false)
       tools);
  cleanup_dir base_path

let test_handle_request_tools_list_include_usage_metadata () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 121);
    ("method", `String "tools/list");
    ("params", `Assoc [ ("include_usage", `Bool true) ]);
  ]) in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let result_fields = result_fields_exn response in
  Alcotest.(check bool) "usage telemetry availability exposed" true
    (List.mem_assoc "usageTelemetryAvailable" result_fields);
  Alcotest.(check bool) "usage total exposed" true
    (List.mem_assoc "usageTotalCalls" result_fields);
  let first_tool =
    match tools_from_response response with
    | tool :: _ -> tool
    | [] -> Alcotest.fail "tools list empty"
  in
  Alcotest.(check bool) "per-tool usage count exposed" true
    (Yojson.Safe.Util.member "usageCount" first_tool <> `Null);
  Alcotest.(check bool) "per-tool last-used field present" true
    (List.mem_assoc "usageLastUsedAt"
       (match first_tool with `Assoc fields -> fields | _ -> []));
  cleanup_dir base_path

let _test_execute_tool_trpg_flow () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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

(* Governance status tool is no longer dispatched *)

let _test_execute_tool_trpg_validation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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
  (* masc_init pruned from registry — dispatch fails. Initialise the
     room state directly so downstream masc_join succeeds. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
  let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in

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
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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
  (* masc_init pruned from registry — dispatch fails. Initialise the
     room state directly so downstream masc_join succeeds. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
  let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in

  let _added =
    Masc_mcp.Coord.add_task state.room_config
      ~title:"alias-reuse-task"
      ~priority:2
      ~description:
        "Verify that an explicit alias can reuse the nickname established during claim/start/done transitions."
  in

  let transition ?(extra = []) action =
    let base_args =
      [
        ("task_id", `String "task-001");
        ("action", `String action);
        ("agent_name", `String "alpha-agent");
      ]
    in
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_transition"
      ~arguments:(`Assoc (extra @ base_args))
  in

  let (ok_claim, claim_msg) = transition "claim" in
  Alcotest.(check bool) "claim success" true ok_claim;
  Alcotest.(check bool) "claim message has claimed" true (contains_substring claim_msg "claimed");

  let (ok_start, start_msg) = transition "start" in
  Alcotest.(check bool) "start success with same explicit alias" true ok_start;
  Alcotest.(check bool) "start message has in_progress" true (contains_substring start_msg "in_progress");

  let (ok_done, done_msg) =
    transition
      ~extra:
        [
          ( "notes",
            `String
              "Completed the alias reuse regression by claiming, starting, and finishing task-001 with the same explicit alias, confirming the joined nickname stayed stable and the transition responses reported success." );
        ]
      "done"
  in
  Alcotest.(check bool) "done success with same explicit alias" true ok_done;
  Alcotest.(check bool) "done message has done" true (contains_substring done_msg "done");

  cleanup_dir base_path

let test_execute_tool_generated_agent_name_uses_token_identity () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Types.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Types.masc_error_to_string e)
  in

  let (ok_status, _status_msg) =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
      ~name:"masc_auth_status"
      ~arguments:(`Assoc [("agent_name", `String "dashboard-eager-manta")])
  in
  (* masc_auth_status tool pruned from registry; dispatch should fail. *)
  Alcotest.(check bool) "auth status fails (tool pruned)" false ok_status;

  cleanup_dir base_path

let check_task_still_todo config task_id =
  match
    Masc_mcp.Coord.get_tasks_raw config
    |> List.find_opt (fun (task : Types.task) -> task.id = task_id)
  with
  | Some { Types.task_status = Types.Todo; _ } -> ()
  | Some task ->
      Alcotest.failf "expected %s to remain todo, got %s" task_id
        (Types.task_status_to_string task.task_status)
  | None -> Alcotest.failf "expected task %s to exist" task_id

let check_auth_preflight_result ~tool_name ok msg =
  Alcotest.(check bool) (tool_name ^ " rejected before handler") false ok;
  Alcotest.(check bool) (tool_name ^ " reports auth/credential blocker") true
    (contains_substring msg "Token required"
     || contains_substring msg "Unauthorized"
     || contains_substring msg "No credential")

let test_execute_tool_explicit_generated_alias_claim_next_not_rewritten_by_token () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Types.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Types.masc_error_to_string e)
  in
  ignore (Masc_mcp.Coord.join state.room_config ~agent_name:"stable-admin" ~capabilities:[] ());
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"explicit-alias-claim-next"
       ~priority:2 ~description:"");
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
      ~name:"masc_claim_next"
      ~arguments:(`Assoc [ ("agent_name", `String "dashboard-eager-manta") ])
  in
  check_auth_preflight_result ~tool_name:"masc_claim_next" ok msg;
  check_task_still_todo state.room_config "task-001";
  cleanup_dir base_path

let test_execute_tool_explicit_generated_alias_transition_not_rewritten_by_token () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Types.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Types.masc_error_to_string e)
  in
  ignore (Masc_mcp.Coord.join state.room_config ~agent_name:"stable-admin" ~capabilities:[] ());
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"explicit-alias-transition"
       ~priority:2 ~description:"");
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
      ~name:"masc_transition"
      ~arguments:
        (`Assoc
          [
            ("agent_name", `String "dashboard-eager-manta");
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
  in
  check_auth_preflight_result ~tool_name:"masc_transition" ok msg;
  check_task_still_todo state.room_config "task-001";
  cleanup_dir base_path

let test_execute_tool_hyphenated_generated_alias_claim_next_reuses_base_token () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc_mcp.Auth.create_token base_path ~agent_name:"qa-king" ~role:Types.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Types.masc_error_to_string e)
  in
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"hyphenated-generated-alias-claim-next"
       ~priority:2 ~description:"");
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:"sid-hyphenated-generated-alias"
      ~auth_token:raw_token state
      ~name:"masc_claim_next"
      ~arguments:(`Assoc [ ("agent_name", `String "qa-king-warm-heron") ])
  in
  if not ok then Alcotest.failf "claim_next failed: %s" msg;
  Alcotest.(check bool) "claim_next reports claimed task" true
    (contains_substring msg "task-001");
  Alcotest.(check (option string)) "current task set after claim_next"
    (Some "task-001")
    (Masc_mcp.Planning_eio.get_current_task state.room_config);
  Alcotest.(check bool) "explicit alias joined" true
    (Masc_mcp.Coord.is_agent_joined state.room_config
       ~agent_name:"qa-king-warm-heron");
  cleanup_dir base_path

let test_execute_tool_claim_next_requires_auth_before_mutation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  ignore (Masc_mcp.Coord.join state.room_config ~agent_name:"uncredentialed-agent" ~capabilities:[] ());
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"claim-next-auth-preflight"
       ~priority:2 ~description:"");
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_claim_next"
      ~arguments:(`Assoc [ ("agent_name", `String "uncredentialed-agent") ])
  in
  check_auth_preflight_result ~tool_name:"masc_claim_next" ok msg;
  check_task_still_todo state.room_config "task-001";
  Alcotest.(check (option string)) "no current task after rejected claim_next" None
    (Masc_mcp.Planning_eio.get_current_task state.room_config);
  cleanup_dir base_path

let test_execute_tool_transition_requires_auth_before_mutation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  ignore (Masc_mcp.Coord.join state.room_config ~agent_name:"uncredentialed-agent" ~capabilities:[] ());
  ignore
    (Masc_mcp.Coord.add_task state.room_config ~title:"transition-auth-preflight"
       ~priority:2 ~description:"");
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_transition"
      ~arguments:
        (`Assoc
          [
            ("agent_name", `String "uncredentialed-agent");
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
  in
  check_auth_preflight_result ~tool_name:"masc_transition" ok msg;
  check_task_still_todo state.room_config "task-001";
  Alcotest.(check (option string)) "no current task after rejected transition" None
    (Masc_mcp.Planning_eio.get_current_task state.room_config);
  cleanup_dir base_path

let test_execute_tool_add_task_with_admin_token_without_join () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Types.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Types.masc_error_to_string e)
  in
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
      ~name:"masc_add_task"
      ~arguments:
        (`Assoc
          [
            ("title", `String "admin add without join");
            ("priority", `Int 2);
            ("description", `String "");
          ])
  in
  Alcotest.(check bool) "add_task succeeds" true ok;
  Alcotest.(check bool) "response mentions added task" true
    (contains_substring msg "Added task-001");
  let task =
    match Masc_mcp.Coord.get_tasks_raw state.room_config with
    | [ task ] -> task
    | tasks ->
        Alcotest.failf "expected exactly one task, found %d" (List.length tasks)
  in
  Alcotest.(check (option string)) "created_by set from token owner"
    (Some "stable-admin") task.created_by;
  Alcotest.(check string) "task remains todo" "todo"
    (Types.task_status_to_string task.task_status);
  cleanup_dir base_path

let test_execute_tool_http_auth_token_overrides_stale_argument_token () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Types.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Types.masc_error_to_string e)
  in
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
      ~name:"masc_status"
      ~arguments:
        (`Assoc
          [
            ("token", `String "stale-argument-token");
          ])
  in
  Alcotest.(check bool) "status succeeds" true ok;
  Alcotest.(check bool) "does not report stale token mismatch" false
    (contains_substring msg "Token mismatch");
  cleanup_dir base_path

let test_execute_tool_legacy_argument_token_still_authorizes_without_http_auth () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  ignore (Masc_mcp.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc_mcp.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Types.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Types.masc_error_to_string e)
  in
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"masc_status"
      ~arguments:
        (`Assoc
          [
            ("token", `String raw_token);
          ])
  in
  Alcotest.(check bool) "status succeeds" true ok;
  Alcotest.(check bool) "status response returned" true
    (String.length msg > 0);
  cleanup_dir base_path

let test_execute_tool_mcp_session_ignores_term_persistence () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-term-isolation-regression" in
  let term_sid = "mcp-eio-term-isolation" in
  let term_file = Printf.sprintf "/tmp/.masc_agent_%s" term_sid in

  with_env "TERM_SESSION_ID" term_sid (fun () ->
    write_text_file term_file "intruder-sage-tiger";

    let (ok_init, _init_msg) =
      Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
        ~name:"masc_init"
        ~arguments:(`Assoc [])
    in
    (* masc_init pruned from registry — dispatch fails. Initialise
       the room state directly so downstream broadcast succeeds. *)
    Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
    let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in

    let (ok_broadcast, _broadcast_msg) =
      Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
        ~name:"masc_broadcast"
        ~arguments:(`Assoc [("message", `String "term isolation check")])
    in
    Alcotest.(check bool) "broadcast success" true ok_broadcast;

    let agents = Masc_mcp.Coord.get_agents_raw state.room_config in
    let names = List.map (fun (a : Types.agent) -> a.name) agents in
    Alcotest.(check bool)
      "mcp session must not reuse TERM_SESSION_ID persisted nickname"
      false
      (List.mem "intruder-sage-tiger" names);

    (try Unix.unlink term_file with Unix.Unix_error _ -> ()));

  cleanup_dir base_path

(* Legacy governance convo tools are stubs; room-scoped test removed *)

let _test_handle_request_tools_call_trpg () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 9);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "trpg.dice.roll");
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
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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

(* masc_cache_get structured content test removed: cache tools retired from MCP surface (#3640) *)
let test_handle_request_tools_call_board_post_structured_content () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  (* board_dispatch auto-inits the board backend by forking under the
     global Eio_context switch. Publish the local sw so the forked fiber
     doesn't land on a finished switch from a prior test case. *)
  Eio_context.set_switch sw;

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 117);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_board_post");
      ("arguments", `Assoc [
        ("content", `String "hello board");
        ("author", `String "tester");
      ]);
    ]);
  ]) in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let structured = structured_content_exn response in
  Alcotest.(check string) "board content" "hello board"
    Yojson.Safe.Util.(structured |> member "content" |> to_string);
  Alcotest.(check string) "board author" "tester"
    Yojson.Safe.Util.(structured |> member "author" |> to_string);
  cleanup_dir base_path

let test_handle_request_tools_call_logs_structured_mcp_details () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  Eio_context.set_switch sw;

  let baseline = latest_log_seq () in
  let base_path = temp_dir () in
  let request_id = "1201" in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
      let request =
        Yojson.Safe.to_string
          (`Assoc
            [
              ("jsonrpc", `String "2.0");
              ("id", `Int 1201);
              ("method", `String "tools/call");
              ( "params",
                `Assoc
                  [
                    ("name", `String "masc_board_post");
                    ( "arguments",
                      `Assoc
                        [
                          ("content", `String "log details parity");
                          ("author", `String "tester");
                        ] );
                  ] );
            ])
      in
      let response =
        Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:"session-log" state
          request
      in
      ignore (result_fields_exn response);
      let entries =
        Masc_log.Ring.recent ~limit:20 ~module_filter:"MCP"
          ~since_seq:baseline ~order:`Oldest_first ()
      in
      let started =
        find_mcp_tool_log_exn ~phase:"started" ~tool_name:"masc_board_post"
          ~request_id entries
      in
      let result =
        find_mcp_tool_log_exn ~phase:"result" ~tool_name:"masc_board_post"
          ~request_id entries
      in
      let completed =
        find_mcp_tool_log_exn ~phase:"completed" ~tool_name:"masc_board_post"
          ~request_id entries
      in
      let check_common label (entry : Masc_log.Ring.entry) =
        let details = entry.details in
        Alcotest.(check string) (label ^ " event_family") "tool_call"
          (json_string_field_exn label details "event_family");
        Alcotest.(check string) (label ^ " session") "session-log"
          (json_string_field_exn label details "session_id")
      in
      check_common "started" started;
      check_common "result" result;
      check_common "completed" completed;
      Alcotest.(check string) "completed outcome" "ok"
        (json_string_field_exn "completed" completed.details "outcome");
      Alcotest.(check string) "result outcome" "ok"
        (json_string_field_exn "result" result.details "outcome"))

let test_handle_request_tools_call_records_keeper_usage_for_public_mcp () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Keeper_registry.clear ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
      let keeper_name = "sangsu" in
      let keeper_agent_name = Keeper_types.keeper_agent_name keeper_name in
      ignore
        (Keeper_registry.register ~base_path keeper_name
           (make_keeper_meta ~agent_name:keeper_agent_name keeper_name));
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      ignore (Masc_mcp.Coord.init state.room_config ~agent_name:None);
      let request =
        Yojson.Safe.to_string
          (`Assoc
            [
              ("jsonrpc", `String "2.0");
              ("id", `Int 119);
              ("method", `String "tools/call");
              ( "params",
                `Assoc
                  [
                    ("name", `String "masc_status");
                    ( "arguments",
                      `Assoc
                        [ ("_agent_name", `String keeper_agent_name) ] );
                  ] );
            ])
      in
      let response = Mcp_eio.handle_request ~clock ~sw state request in
      ignore (result_fields_exn response);
      match List.assoc_opt "masc_status" (Keeper_registry.tool_usage_of ~base_path keeper_name) with
      | Some entry ->
          Alcotest.(check int) "tool count" 1 entry.count;
          Alcotest.(check int) "tool successes" 1 entry.successes;
          Alcotest.(check int) "tool failures" 0 entry.failures;
          let persisted =
            Yojson.Safe.from_file
              (Filename.concat base_path ".masc/keepers/tool_usage/sangsu.json")
          in
          let open Yojson.Safe.Util in
          Alcotest.(check string) "persisted tool name" "masc_status"
            (persisted |> member "tools" |> index 0 |> member "tool" |> to_string)
      | None -> Alcotest.fail "expected keeper tool usage for masc_status")

let test_handle_request_tools_call_blocks_keeper_internal_tool () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 118);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "keeper_time_now");
      ("arguments", `Assoc []);
    ]);
  ]) in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "error code" (-32601) (error_code_exn response);
  let msg = error_message_exn response in
  Alcotest.(check bool) "mentions keeper-internal" true
    (try
       ignore (Str.search_forward (Str.regexp_case_fold "keeper-internal") msg 0);
       true
     with Not_found -> false);
  cleanup_dir base_path

let test_handle_request_batch_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`List
        [
          `Assoc
            [
              ("jsonrpc", `String "2.0");
              ("id", `Int 1);
              ("method", `String "tools/list");
              ("params", `Assoc []);
            ];
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "batch rejected" (-32600) (error_code_exn response);
  Alcotest.(check bool) "mentions batch unsupported" true
    (contains_substring (error_message_exn response) "batch requests are not supported");
  cleanup_dir base_path

let test_handle_request_jsonrpc_response_returns_null () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 1);
          ("result", `String "already a response");
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check bool) "response ignored" true (response = `Null);
  cleanup_dir base_path

let test_handle_request_method_not_found () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
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

let test_handle_request_tools_list_rejects_empty_cursor () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 2300);
          ("method", `String "tools/list");
          ("params", `Assoc [ ("cursor", `String "   ") ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check string) "empty cursor error"
    "Invalid params: cursor must not be empty"
    (error_message_exn response);
  cleanup_dir base_path

let test_handle_request_tools_list_rejects_tier_field () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 2301);
          ("method", `String "tools/list");
          ("params", `Assoc [ ("tier", `String "impossible") ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check bool) "unsupported tier error" true
    (contains_substring (error_message_exn response) "unsupported field(s): tier");
  cleanup_dir base_path

let test_handle_request_resources_list_rejects_unknown_field () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 2302);
          ("method", `String "resources/list");
          ("params", `Assoc [ ("page", `Int 2) ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check bool) "unknown field rejected" true
    (contains_substring (error_message_exn response) "unsupported field");
  cleanup_dir base_path

let test_handle_request_resources_templates_rejects_invalid_cursor () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 2303);
          ("method", `String "resources/templates/list");
          ("params", `Assoc [ ("cursor", `String "not-base64") ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check string) "invalid cursor error"
    "Invalid params: cursor is invalid"
    (error_message_exn response);
  cleanup_dir base_path

let test_handle_request_prompts_list_rejects_invalid_cursor () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 2304);
          ("method", `String "prompts/list");
          ("params", `Assoc [ ("cursor", `String "bad-cursor") ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check string) "invalid cursor error"
    "Invalid params: cursor is invalid"
    (error_message_exn response);
  cleanup_dir base_path

let test_handle_request_prompts_list_non_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 21);
          ("method", `String "prompts/list");
          ("params", `Assoc []);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let prompts =
    match response with
    | `Assoc fields -> (
        match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) -> (
            match List.assoc_opt "prompts" result_fields with
            | Some (`List prompts) -> prompts
            | _ -> Alcotest.fail "prompts not a list")
        | _ -> Alcotest.fail "result not an object")
    | _ -> Alcotest.fail "response not an object"
  in
  Alcotest.(check bool) "prompt inventory is non-empty" true
    (List.length prompts >= 3);
  cleanup_dir base_path

let test_handle_request_prompts_list_cursor () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let cursor = Base64.encode_string "prompts:1" in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 210);
          ("method", `String "prompts/list");
          ("params", `Assoc [ ("cursor", `String cursor) ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let prompts =
    match response with
    | `Assoc fields -> (
        match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) -> (
            match List.assoc_opt "prompts" result_fields with
            | Some (`List prompts) -> prompts
            | _ -> Alcotest.fail "prompts not a list")
        | _ -> Alcotest.fail "result not an object")
    | _ -> Alcotest.fail "response not an object"
  in
  Alcotest.(check int) "cursor trims first prompt" 2 (List.length prompts);
  cleanup_dir base_path

let test_handle_request_prompts_get_tool_help () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 22);
          ("method", `String "prompts/get");
          ( "params",
            `Assoc
              [
                ("name", `String "tool_help");
                ("arguments", `Assoc [ ("tool_name", `String "masc_status") ]);
              ] );
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let description, messages =
    match response with
    | `Assoc fields -> (
        match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) -> (
            let description =
              match List.assoc_opt "description" result_fields with
              | Some (`String value) -> value
              | _ -> Alcotest.fail "prompt description missing"
            in
            let messages =
              match List.assoc_opt "messages" result_fields with
              | Some (`List items) -> items
              | _ -> Alcotest.fail "prompt messages missing"
            in
            (description, messages))
        | _ -> Alcotest.fail "result not an object")
    | _ -> Alcotest.fail "response not an object"
  in
  Alcotest.(check bool) "description contains help intent" true
    (contains_substring description "tool");
  Alcotest.(check bool) "prompt has one or more messages" true
    (messages <> []);
  cleanup_dir base_path

(* test_handle_request_prompts_get_command_truth_filters_run_id removed
   (CP purge: Command_plane_v2 event_record + append_event deleted) *)

let test_handle_request_resources_list_includes_tool_help () =
  with_env "MASC_LIST_PAGE_SIZE" "10" @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let resources = resources_list_all ~clock ~sw state [] in
  let tool_help_index_present =
    List.exists
      (function
        | `Assoc fields -> List.assoc_opt "uri" fields = Some (`String "masc://tool-help-index")
        | _ -> false)
      resources
  in
  Alcotest.(check bool) "tool help index listed" true tool_help_index_present;
  cleanup_dir base_path

let test_handle_request_resources_list_paginates () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 230);
          ("method", `String "resources/list");
          ("params", `Assoc []);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let resources =
    match response with
    | `Assoc fields -> (
        match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) -> (
            match List.assoc_opt "resources" result_fields with
            | Some (`List resources) -> resources
            | _ -> Alcotest.fail "resources not a list")
        | _ -> Alcotest.fail "result not an object")
    | _ -> Alcotest.fail "response not an object"
  in
  (* Resource count varies as tools are added/removed. Verify non-empty. *)
  let resource_count = List.length resources in
  Alcotest.(check bool) "resources non-empty" true (resource_count > 0);
  Alcotest.(check bool) "resources reasonable count (>= 10)" true (resource_count >= 10);
  cleanup_dir base_path

let test_handle_request_tools_list_paginates () =
  with_env "MASC_LIST_PAGE_SIZE" "10" @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let first_page = tools_list_response ~clock ~sw state in
  let first_tools = tools_from_response first_page in
  let cursor =
    match next_cursor_of_response first_page with
    | Some cursor -> cursor
    | None -> Alcotest.fail "expected nextCursor on tools/list first page"
  in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 240);
          ("method", `String "tools/list");
          ("params", `Assoc [ ("cursor", `String cursor) ]);
        ])
  in
  let second_page = Mcp_eio.handle_request ~clock ~sw state request in
  let second_tools = tools_from_response second_page in
  let first_name =
    match List.hd first_tools with
    | `Assoc fields -> (
        match List.assoc_opt "name" fields with
        | Some (`String name) -> name
        | _ -> Alcotest.fail "first page tool missing name")
    | _ -> Alcotest.fail "first page tool not an object"
  in
  let second_name =
    match List.hd second_tools with
    | `Assoc fields -> (
        match List.assoc_opt "name" fields with
        | Some (`String name) -> name
        | _ -> Alcotest.fail "second page tool missing name")
    | _ -> Alcotest.fail "second page tool not an object"
  in
  Alcotest.(check int) "tools first page size" 10 (List.length first_tools);
  Alcotest.(check bool) "tools second page non-empty" true
    (List.length second_tools > 0);
  Alcotest.(check bool) "pages advance" true
    (not (String.equal first_name second_name));
  cleanup_dir base_path

let test_handle_request_tool_help_resource_read () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 24);
          ("method", `String "resources/read");
          ("params", `Assoc [ ("uri", `String "masc://tool-help/masc_status") ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  let text =
    match response with
    | `Assoc fields -> (
        match List.assoc_opt "result" fields with
        | Some (`Assoc result_fields) -> (
            match List.assoc_opt "contents" result_fields with
            | Some (`List (`Assoc content_fields :: _)) -> (
                match List.assoc_opt "text" content_fields with
                | Some (`String value) -> value
                | _ -> Alcotest.fail "resource text missing")
            | _ -> Alcotest.fail "resource contents missing")
        | _ -> Alcotest.fail "result not an object")
    | _ -> Alcotest.fail "response not an object"
  in
  Alcotest.(check bool) "resource contains heading" true
    (contains_substring text "# masc_status");
  cleanup_dir base_path

let test_handle_request_resources_read_matrix () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc_mcp.Coord.init state.room_config ~agent_name:(Some "fixture-root"));
  let ensure_dir path =
    if not (Sys.file_exists path) then Unix.mkdir path 0o755
  in
  let library_dir = Filename.concat base_path "docs/library" in
  let masc_dir = Filename.concat base_path Common.masc_dirname in
  ensure_dir (Filename.concat base_path "docs");
  ensure_dir library_dir;
  ensure_dir masc_dir;
  write_text_file (Filename.concat library_dir "alpha.md")
    {|---
title: Alpha Doc
source: https://example.com/alpha
verified_by: codex
date: 2026-03-12
tags: [alpha, keeper]
---
Alpha body
|};
  write_text_file (Filename.concat masc_dir "institution.json")
    {|{
  "identity": {
    "id": "inst-1",
    "name": "Fixture Institution",
    "mission": "Keep collective memory coherent",
    "founded_at": 0.0,
    "generation": 1
  },
  "memory": {
    "episodic": [],
    "semantic": [],
    "procedural": []
  },
  "culture": [],
  "succession": {
    "onboarding_steps": ["Read mission"],
    "required_knowledge": [],
    "mentor_assignment": "best_fit",
    "probation_period": 24.0,
    "graduation_criteria": ["Ship one task"]
  },
  "current_agents": [],
  "alumni": []
}|};
  let cases =
    [
      ("masc://status.json", "application/json", "\"base_path\"");
      ("masc://tasks.json", "application/json", "\"tasks\"");
      ("masc://who.json", "application/json", "[");
      ("masc://agents.json", "application/json", "{");
      ("masc://messages.json", "application/json", "[");
      ("masc://events.json", "application/json", "[");
      ("masc://worktrees.json", "application/json", "{");
      ("masc://schema.json", "application/json", "{");
      ("masc://institution", "text/markdown", "Mission");
      ("masc://institution.json", "application/json", "\"identity\"");
      ("masc://library", "text/markdown", "Library Index");
      ("masc://library.json", "application/json", "\"documents\"");
      ("masc://library/alpha", "text/markdown", "Alpha body");
      ("masc://library/alpha.json", "application/json", "\"Alpha body\"");
    ]
  in
  List.iter
    (fun (uri, expected_mime, expected_text) ->
      let request =
        Yojson.Safe.to_string
          (`Assoc
            [
              ("jsonrpc", `String "2.0");
              ("id", `Int 250);
              ("method", `String "resources/read");
              ("params", `Assoc [ ("uri", `String uri) ]);
            ])
      in
      let response = Mcp_eio.handle_request ~clock ~sw state request in
      Alcotest.(check string) (uri ^ " mime type") expected_mime
        (resource_mime_type_exn response);
      Alcotest.(check bool) (uri ^ " text contains expected") true
        (contains_substring (resource_text_exn response) expected_text))
    cases;
  cleanup_dir base_path

let test_handle_request_resources_subscribe_requires_session () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 240);
          ("method", `String "resources/subscribe");
          ("params", `Assoc [ ("uri", `String "masc://status") ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  (match response with
   | `Assoc fields ->
       Alcotest.(check bool) "subscribe requires session" true
         (List.mem_assoc "error" fields)
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_resources_subscribe_roundtrip () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let subscribe_request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 241);
          ("method", `String "resources/subscribe");
          ("params", `Assoc [ ("uri", `String "masc://status") ]);
        ])
  in
  let subscribe_response =
    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:"session-spec" state
      subscribe_request
  in
  (match subscribe_response with
   | `Assoc fields ->
       Alcotest.(check bool) "subscribe ok" true
         (List.mem_assoc "result" fields)
   | _ -> Alcotest.fail "subscribe response not an object");
  let unsubscribe_request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 242);
          ("method", `String "resources/unsubscribe");
          ("params", `Assoc [ ("uri", `String "masc://status") ]);
        ])
  in
  let unsubscribe_response =
    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:"session-spec" state
      unsubscribe_request
  in
  (match unsubscribe_response with
   | `Assoc fields ->
       Alcotest.(check bool) "unsubscribe ok" true
         (List.mem_assoc "result" fields)
   | _ -> Alcotest.fail "unsubscribe response not an object");
  cleanup_dir base_path

let test_execute_tool_help_tool () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let ok, msg =
    Mcp_eio.execute_tool_eio ~sw ~clock state ~name:"masc_tool_help"
      ~arguments:(`Assoc [ ("tool_name", `String "masc_status") ])
  in
  Alcotest.(check bool) "tool help call succeeds" true ok;
  let json = extract_json_from_text msg in
  Alcotest.(check string) "help tool echoes name" "masc_status"
    Yojson.Safe.Util.(json |> member "name" |> to_string);
  cleanup_dir base_path

let test_execute_tool_tag_dispatch_respects_pre_hooks () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Tool_dispatch.clear_hooks ();
      cleanup_dir base_path)
    (fun () ->
      Tool_dispatch.clear_hooks ();
      Tool_dispatch.register_pre_hook
        (fun ~name ~args:_ ->
          if String.equal name "masc_tool_help" then
            Tool_dispatch.Reject
              {
                Tool_result.success = false;
                data = `String "blocked-by-pre-hook";
                tool_name = name;
                duration_ms = 0.0;
              }
          else Tool_dispatch.Pass);
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let _room_path = Masc_mcp.Coord.masc_dir state.room_config in
      let ok, msg =
        Mcp_eio.execute_tool_eio ~sw ~clock state ~name:"masc_tool_help"
          ~arguments:(`Assoc [ ("tool_name", `String "masc_status") ])
      in
      Alcotest.(check bool) "pre-hook blocks tagged dispatch" false ok;
      Alcotest.(check string) "blocked message returned" "blocked-by-pre-hook" msg)

let test_execute_tool_autoresearch_uses_resolved_session_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let workdir_path = Filename.concat base_path "not-a-git-repo" in
  Unix.mkdir workdir_path 0o755;
  Fun.protect
    ~finally:(fun () ->
      Tool_dispatch.clear_hooks ();
      cleanup_dir base_path)
    (fun () ->
      Tool_dispatch.clear_hooks ();
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let sid = "mcp-autoresearch-session-agent" in
      let (ok_init, _) =
        Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
          ~name:"masc_init" ~arguments:(`Assoc [])
      in
      (* masc_init pruned from registry — dispatch fails. Initialise
         the room state directly so downstream masc_join succeeds. *)
      Alcotest.(check bool) "init returns failure (tool pruned)" false ok_init;
      let _ = Masc_mcp.Coord.init state.room_config ~agent_name:None in
      let (ok_join, _) =
        Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
          ~name:"masc_join"
          ~arguments:(`Assoc [ ("agent_name", `String "codex") ])
      in
      Alcotest.(check bool) "join success" true ok_join;
      let (ok_start, msg) =
        Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
          ~name:"masc_autoresearch_start"
          ~arguments:
            (`Assoc
              [
                ("goal", `String "permission regression");
                ("metric_fn", `String "echo");
                ("target_file", `String "target.txt");
                ("workdir", `String workdir_path);
                ("model_model", `String "test:dummy");
                ("max_cycles", `Int 1);
              ])
      in
      Alcotest.(check bool) "start fails" false ok_start;
      (* Without the legacy Tool_permissions pre-hook, the call reaches
         workdir validation which rejects non-git directories. *)
      Alcotest.(check bool) "fails at workdir validation" true
        (contains_substring msg "workdir is not inside a git repository"))

(* ===== Test Suites ===== *)

let state_tests = [
  "create_state", `Quick, test_create_state;
  "type compatibility", `Quick, test_type_compatibility;
  "eio context delegation", `Quick, test_eio_context_delegation;
  "eio context scoped restore", `Quick, test_eio_context_with_test_env_restores;
  "resolve_join_state skips read-only lookup", `Quick,
    test_resolve_join_state_skips_read_only_lookup;
  "resolve_join_state checks join-required tools", `Quick,
    test_resolve_join_state_checks_join_required_tools;
  "resolve_join_state skips unknown agent", `Quick,
    test_resolve_join_state_skips_unknown_agent;
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
  "handle initialize rejects unsupported protocol version", `Quick,
    test_handle_request_initialize_rejects_unsupported_protocol_version;
  "handle initialize operator profile", `Quick,
    test_handle_request_initialize_operator_profile;
  "handle tools/list", `Quick, test_handle_request_tools_list;
  "handle tools/list rejects empty cursor", `Quick,
    test_handle_request_tools_list_rejects_empty_cursor;
  "handle tools/list rejects tier field", `Quick,
    test_handle_request_tools_list_rejects_tier_field;
  "handle prompts/list non-empty", `Quick, test_handle_request_prompts_list_non_empty;
  "handle prompts/list cursor", `Quick, test_handle_request_prompts_list_cursor;
  "handle prompts/list rejects invalid cursor", `Quick,
    test_handle_request_prompts_list_rejects_invalid_cursor;
  "handle prompts/get tool_help", `Quick, test_handle_request_prompts_get_tool_help;
  (* handle prompts/get command_truth filters run_id removed (CP purge) *)
  "handle resources/list includes tool-help", `Quick, test_handle_request_resources_list_includes_tool_help;
  "handle resources/list rejects unknown field", `Quick,
    test_handle_request_resources_list_rejects_unknown_field;
  "handle resources/list paginates", `Quick,
    test_handle_request_resources_list_paginates;
  "handle resources/read tool-help", `Quick, test_handle_request_tool_help_resource_read;
  "handle resources/read matrix", `Quick, test_handle_request_resources_read_matrix;
  "handle resources/templates/list rejects invalid cursor", `Quick,
    test_handle_request_resources_templates_rejects_invalid_cursor;
  "handle resources/subscribe requires session", `Quick,
    test_handle_request_resources_subscribe_requires_session;
  "handle resources/subscribe roundtrip", `Quick,
    test_handle_request_resources_subscribe_roundtrip;
  "execute masc_tool_help", `Quick, test_execute_tool_help_tool;
  "execute tag dispatch respects pre-hooks", `Quick,
    test_execute_tool_tag_dispatch_respects_pre_hooks;
  "execute autoresearch uses resolved session agent", `Quick,
    test_execute_tool_autoresearch_uses_resolved_session_agent;
  "handle tools/list filters requested names", `Quick,
    test_handle_request_tools_list_rejects_nonstandard_names_filter;
  "handle initialize managed profile", `Quick,
    test_handle_request_initialize_managed_profile;
  "handle tools/list managed profile", `Quick,
    test_handle_request_tools_list_managed_profile;
  "handle tools/list operator profile", `Quick,
    test_handle_request_tools_list_operator_profile;
  "handle tools/list with placeholder flag", `Quick, test_handle_request_tools_list_with_placeholder_flag;
  "handle tools/list include hidden metadata", `Quick,
    test_handle_request_tools_list_include_hidden_metadata;
  "handle tools/list include deprecated claim alias metadata", `Quick,
    test_handle_request_tools_list_include_deprecated_claim_alias_metadata;
  (* execution_session_turn hide test removed — team session cleanup *)
  "handle tools/list include usage metadata", `Quick,
    test_handle_request_tools_list_include_usage_metadata;
  "handle tools/list paginates", `Quick, test_handle_request_tools_list_paginates;
  "handle batch request rejected", `Quick, test_handle_request_batch_rejected;
  "handle jsonrpc response returns null", `Quick,
    test_handle_request_jsonrpc_response_returns_null;
  "reject non-operator tool on operator profile", `Quick,
  test_handle_request_tools_call_operator_profile_rejects_non_operator;
  "handle tools/call managed profile sdk alias claim", `Quick,
    test_handle_request_tools_call_managed_profile_sdk_alias_claim;
  "handle tools/call transition claim guidance", `Quick,
    test_handle_request_tools_call_transition_claim_guidance;
  "handle tools/call transition done guidance", `Quick,
    test_handle_request_tools_call_transition_done_guidance;
  "handle tools/call transition claim requires action", `Quick,
    test_handle_request_tools_call_transition_claim_requires_action;
  (* cache get structured content test removed: cache tools retired (#3640) *)
  "handle tools/call board post structured content", `Quick,
    test_handle_request_tools_call_board_post_structured_content;
  "handle tools/call logs structured MCP details", `Quick,
    test_handle_request_tools_call_logs_structured_mcp_details;
  "handle tools/call records keeper usage for public MCP tool", `Quick,
    test_handle_request_tools_call_records_keeper_usage_for_public_mcp;
  "handle tools/call blocks keeper internal tool", `Quick,
    test_handle_request_tools_call_blocks_keeper_internal_tool;
  "handle invalid json", `Quick, test_handle_request_invalid_json;
  "handle method not found", `Quick, test_handle_request_method_not_found;
  (* TRPG tool tests removed — modules archived *)
  (* Governance status tool test removed *)
  (* execution_session_step direct call test removed — team session cleanup *)
  "legacy persisted agent read only for ephemeral names", `Quick,
    test_should_read_legacy_persisted_agent_name;
  "explicit agent_name not overridden", `Quick, test_execute_tool_explicit_agent_name_not_overridden;
  "explicit alias reuses joined nickname", `Quick, test_execute_tool_explicit_alias_reuses_joined_nickname;
  "generated agent_name uses token identity", `Quick,
    test_execute_tool_generated_agent_name_uses_token_identity;
  "explicit generated alias claim_next not rewritten by token", `Quick,
    test_execute_tool_explicit_generated_alias_claim_next_not_rewritten_by_token;
  "explicit generated alias transition not rewritten by token", `Quick,
    test_execute_tool_explicit_generated_alias_transition_not_rewritten_by_token;
  "hyphenated generated alias claim_next reuses base token", `Quick,
    test_execute_tool_hyphenated_generated_alias_claim_next_reuses_base_token;
  "claim_next auth preflight blocks mutation", `Quick,
    test_execute_tool_claim_next_requires_auth_before_mutation;
  "transition auth preflight blocks mutation", `Quick,
    test_execute_tool_transition_requires_auth_before_mutation;
  "add_task admin token works without join", `Quick,
    test_execute_tool_add_task_with_admin_token_without_join;
  "http auth token overrides stale argument token", `Quick,
    test_execute_tool_http_auth_token_overrides_stale_argument_token;
  "legacy argument token still authorizes without http auth", `Quick,
    test_execute_tool_legacy_argument_token_still_authorizes_without_http_auth;
  "mcp session ignores term persistence", `Quick, test_execute_tool_mcp_session_ignores_term_persistence;
  (* Legacy governance convo room test removed *)
]

let () =
  Alcotest.run "Mcp_server_eio" [
    "state", state_tests;
    "protocol", protocol_tests;
    "response", response_tests;
    "eio", eio_tests;
  ]
