module Types = Masc_domain

(** Test suite for Mcp_server_eio module

    Tests the Eio-native MCP server implementation.
    Uses Eio_main.run for async test context.
*)

module Mcp_eio = Masc.Mcp_server_eio
module Mcp = Masc.Mcp_server
module Mcp_server = Masc.Mcp_server
module Config = Masc.Config
module Client_registry_eio = Masc.Client_registry_eio
module Tool_result = Tool_result
module Keeper_types = Keeper_types
module Keeper_identity = Masc.Keeper_identity
module Keeper_registry = Masc.Keeper_registry
module Keeper_lifecycle_reservation = Masc.Keeper_lifecycle_reservation
module Masc_log = Log

let () =
  Mirage_crypto_rng_unix.use_default ();
  let (_operator_force_link : unit) = Operator_tool.force_link in
  let (_dashboard_ws_sessions : int) = Server_mcp_transport_ws.session_count () in
  Atomic.set
    Workspace_hooks.get_verifier_exact_lane_slots_fn
    (fun () -> Ok (List.map (fun id -> id, Types_core.Catalog_slot) [ "test.local" ]))

let () =
  (* These process-global registries are installed by module initializers in the
     production server path.  Force them in this standalone test executable so
     profile-specific fixtures do not depend on link/load order. *)
  ignore (Operator_tool.remote_tool_names : string list);
  ignore (Server_mcp_transport_ws.session_count : unit -> int)

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

(* [Board_dispatch] auto-inits the process-wide Board backend against the
   workspace of the first call that reaches it, and [Board_dispatch.init_jsonl]
   refuses a different workspace while one is bound. A test case that reaches
   the board binds the global to its temporary directory and then removes the
   directory, so the next board call fails with "Board BasePath is missing"
   (run 41827897543, eio #54: tools/call logs structured MCP details). Every
   test that can reach the board starts with no Board bound and leaves none
   behind, as test_server_runtime_bootstrap does with with_server_state_dir. *)
let reset_board_test_globals () =
  Masc.Board.reset_global_for_test ();
  Masc.Board_dispatch.reset_for_test ()

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

let test_agent_identity ~uuid ~session_key : Masc.Client_identity.t =
  {
    uuid;
    session_key;
    agent_name = "";
    agent_name_origin = `System_fallback;
    channel = None;
    user_id = None;
    capabilities = [];
    registered_at = 0.;
    last_seen = 0.;
    metadata = [];
  }

let make_keeper_meta name =
  let json =
    `Assoc
      [
         ("name", `String name);
         ("trace_id", `String ("trace-test-" ^ name));
       ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> meta
  | Error err -> Alcotest.fail ("make_keeper_meta failed: " ^ err)

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
  | Some profile -> Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~profile state request
  | None -> Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request

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

(* Paging facts live under this server's own [_meta] key rather than as bare
   [_meta] members, where a later spec key could take one of the names. *)
let tools_list_meta_exn response =
  match List.assoc_opt "_meta" (result_fields_exn response) with
  | Some (`Assoc fields) -> (
    match List.assoc_opt Masc.Mcp_server.list_page_meta_key fields with
    | Some (`Assoc page) -> page
    | _ -> Alcotest.fail "list page meta missing")
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
  match Yojson.Safe.Util.member field entry.details with
  | `String value | `Intlit value -> Some value
  | `Int value -> Some (string_of_int value)
  | `Null -> None
  | _ -> None

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
  Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request

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

(* The envelope moved under the server's own [_meta] key: [CallToolResult]
   defines no member to hang it off. *)
let result_envelope_exn response =
  match List.assoc_opt "_meta" (result_fields_exn response) with
  | Some (`Assoc meta) -> (
    match List.assoc_opt Masc.Mcp_server.tool_call_meta_key meta with
    | Some (`Assoc call) -> (
      match List.assoc_opt "envelope" call with
      | Some (`Assoc fields) -> fields
      | _ -> Alcotest.fail "call envelope missing")
    | _ -> Alcotest.fail "tool call meta missing")
  | _ -> Alcotest.fail "result _meta missing"

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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  Alcotest.(check string) "base_path preserved"
    base_path (Mcp_server.workspace_config state).base_path;
  cleanup_dir base_path

let test_type_compatibility () =
  (* Verify Mcp_server_eio.server_state is same type as Mcp_server.server_state *)
  let base_path = temp_dir () in
  let state : Mcp_eio.server_state = Mcp_eio.For_testing.create_state ~base_path () in
  let state2 : Mcp.server_state = state in  (* Type unification at compile time *)
  (* Verify the unified type preserves field access *)
  Alcotest.(check string) "base_path via unified type" base_path (Mcp_server.workspace_config state2).base_path;
  cleanup_dir base_path

let test_eio_context_delegation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Mcp_eio.set_net net;
  Mcp_eio.set_clock clock;
  let delegated_net = Eio_context.get_net_opt () in
  (* Compare the underlying clock resource, not the Result wrappers.
     Each call to get_clock allocates a fresh [Ok _] box, so
     [Ok a] == [Ok b] is always false even when [a == b]. See #9709. *)
  let direct_clock = Eio_context.get_clock () in
  let alias_clock = Mcp_eio.get_clock () in
  let clock_delegated =
    match direct_clock, alias_clock with
    | Ok a, Ok b -> a == b
    | _, _ -> false
  in
  Alcotest.(check bool) "net delegated to shared Eio_context" true
    (Option.is_some delegated_net);
  Alcotest.(check bool) "clock delegated to shared Eio_context" true
    clock_delegated

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
  Alcotest.(check bool) "valid 2.0" true (Mcp_transport_protocol.is_jsonrpc_v2 valid);
  Alcotest.(check bool) "invalid 1.0" false (Mcp_transport_protocol.is_jsonrpc_v2 invalid);
  Alcotest.(check bool) "no version" false (Mcp_transport_protocol.is_jsonrpc_v2 no_version)

let test_jsonrpc_request_parsing () =
  let json = `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "initialize");
    ("params", `Assoc []);
  ] in
  match Mcp_transport_protocol.jsonrpc_request_of_yojson json with
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
  (match Mcp_transport_protocol.jsonrpc_request_of_yojson with_id with
   | Ok req -> Alcotest.(check bool) "with id" false (Mcp_transport_protocol.is_notification req)
   | Error _ -> Alcotest.fail "parse error");
  (match Mcp_transport_protocol.jsonrpc_request_of_yojson without_id with
   | Ok req -> Alcotest.(check bool) "without id" true (Mcp_transport_protocol.is_notification req)
   | Error _ -> Alcotest.fail "parse error")

let test_protocol_version () =
  let params = Some (`Assoc [("protocolVersion", `String "2025-06-18")]) in
  let version = Mcp_transport_protocol.protocol_version_from_params params in
  Alcotest.(check string) "version extracted" "2025-06-18" version;

  (match Mcp_transport_protocol.validate_protocol_version "2025-06-18" with
   | Ok version ->
       Alcotest.(check string) "2025-06-18 is supported" "2025-06-18" version
   | Error msg -> Alcotest.fail msg);

  let normalized = Mcp_transport_protocol.normalize_protocol_version "unknown" in
  Alcotest.(check string) "normalized to default" "2025-11-25" normalized;

  match Mcp_transport_protocol.validate_protocol_version "unknown" with
  | Error msg ->
      Alcotest.(check bool) "unsupported version rejected" true
        (String_util.contains_substring msg "Unsupported protocolVersion")
  | Ok _ -> Alcotest.fail "expected unsupported protocol version to be rejected"

(* ===== Unit Tests for Response Builders ===== *)

let test_make_response () =
  let response = Mcp_transport_protocol.make_response ~id:(`Int 42) (`String "result") in
  match response with
  | `Assoc fields ->
      let id = List.assoc "id" fields in
      let result = List.assoc "result" fields in
      Alcotest.(check bool) "has jsonrpc" true (List.mem_assoc "jsonrpc" fields);
      Alcotest.(check bool) "id is 42" true (id = `Int 42);
      Alcotest.(check bool) "result is string" true (result = `String "result")
  | _ -> Alcotest.fail "not an object"

let test_make_error () =
  let response = Mcp_transport_protocol.make_error ~id:(`Int 1) (-32600) "Invalid Request" in
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in

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

  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in

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

let test_handle_request_initialize_counteroffers_legacy_version () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in

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

  let expect_legacy response =
    Alcotest.(check (option string)) "counter-offers latest legacy version"
      (Some "2025-11-25")
      (match List.assoc_opt "protocolVersion" (result_fields_exn response) with
       | Some (`String version) -> Some version
       | Some _ | None -> None)
  in
  expect_legacy (Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request);
  let modern_request =
    Yojson.Safe.from_string request
    |> (function
        | `Assoc fields ->
          `Assoc (List.map (function
            | "params", `Assoc params ->
              "params", `Assoc (List.map (function
                | "protocolVersion", _ -> "protocolVersion", `String "2026-07-28"
                | field -> field) params)
            | field -> field) fields)
        | json -> json)
    |> Yojson.Safe.to_string
  in
  expect_legacy (Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state modern_request);

  cleanup_dir base_path

let test_handle_request_server_discover_2026 () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `String "discover-1");
          ("method", `String "server/discover");
          ( "params",
            `Assoc
              [
                ( "_meta",
                  `Assoc
                    [
                      ( Mcp_transport_protocol.protocol_version_meta_key,
                        `String "2026-07-28" );
                      ( "io.modelcontextprotocol/clientInfo",
                        `Assoc
                          [ ("name", `String "test"); ("version", `String "0.1") ]
                      );
                      ("io.modelcontextprotocol/clientCapabilities", `Assoc []);
                    ] );
              ] );
        ])
  in
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  let result = result_fields_exn response in
  Alcotest.(check (option string)) "complete result"
    (Some "complete")
    (match List.assoc_opt "resultType" result with
     | Some (`String value) -> Some value
     | _ -> None);
  (match List.assoc_opt "supportedVersions" result with
   | Some (`List versions) ->
       let versions =
         List.filter_map
           (function
             | `String value -> Some value
             | _ -> None)
           versions
       in
       Alcotest.(check bool) "advertises 2026-07-28" true
         (List.mem "2026-07-28" versions);
       Alcotest.(check bool) "keeps 2025-11-25 compatibility" true
         (List.mem "2025-11-25" versions)
   | _ -> Alcotest.fail "supportedVersions not a list");
  Alcotest.(check bool) "has serverInfo" true
    (List.mem_assoc "serverInfo" result);
  Alcotest.(check bool) "has capabilities" true
    (List.mem_assoc "capabilities" result);
  cleanup_dir base_path

let stdio_modern_params ?(version = "2026-07-28") () =
  `Assoc [ "_meta", `Assoc
    [ Mcp_transport_protocol.protocol_version_meta_key, `String version
    ; Mcp_transport_protocol.client_capabilities_meta_key, `Assoc [] ] ]

let stdio_listen_params () =
  match stdio_modern_params () with
  | `Assoc fields -> `Assoc (("notifications", `Assoc []) :: fields)
  | other -> other

let stdio_request ?id ?params method_ =
  `Assoc
    ([ "jsonrpc", `String "2.0"; "method", `String method_ ]
     @ (match id with Some value -> [ "id", value ] | None -> [])
     @ (match params with Some value -> [ "params", value ] | None -> []))

let run_stdio_messages ?(on_handled = fun _ _ _ -> ()) ~clock ~sw state messages =
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  let input, input_writer = Eio_unix.pipe sw in
  let output, output_writer = Eio_unix.pipe sw in
  let env = object
    method clock = clock
    method stdin = input
    method stdout = output_writer
  end in
  let handle_request ~clock ~sw ~mcp_session_id state request =
    let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ?mcp_session_id state request in
    on_handled mcp_session_id request response;
    response
  in
  let finished, finish = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Flow.close output_writer; Eio.Promise.resolve finish ())
      (fun () -> Masc.Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env state));
  let reader = Eio.Buf_read.of_flow output ~max_size:(1024 * 1024) in
  let input_open = ref true in
  let close_input () =
    if !input_open then (input_open := false; Eio.Flow.close input_writer) in
  let expects_response = function
    | `Assoc fields ->
      List.assoc_opt "jsonrpc" fields <> Some (`String "2.0")
      || List.mem_assoc "id" fields
    | _ -> true in
  Fun.protect
    ~finally:(fun () -> close_input (); if not was_ready then Eio_guard.disable ())
    (fun () ->
      let responses = List.filter_map (fun message ->
        Eio.Flow.copy_string (Yojson.Safe.to_string message ^ "\n") input_writer;
        if expects_response message then
          Some (Eio.Time.with_timeout_exn clock 5. (fun () ->
            Yojson.Safe.from_string (Eio.Buf_read.line reader)))
        else None) messages in
      close_input ();
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished);
      (match Eio.Buf_read.line reader with
       | exception End_of_file -> ()
       | _ -> Alcotest.fail "unexpected trailing stdio response");
      responses)

let test_stdio_admission_and_subscription_cancellation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    let modern = stdio_modern_params () in
    let listen = stdio_listen_params () in
    let cancelled = `Assoc [ "requestId", `Int 3 ] in
    let malformed_cancel = `Assoc
      [ "jsonrpc", `String "1.0"; "method", `String "notifications/cancelled"
      ; "params", cancelled ] in
    let initialize = `Assoc
      [ "protocolVersion", `String "2026-07-28"; "capabilities", `Assoc []
      ; "clientInfo", `Assoc [ "name", `String "test"; "version", `String "1" ] ] in
    let responses = run_stdio_messages ~clock ~sw state
      [ stdio_request ~id:(`Int 1) "server/discover"
      ; stdio_request ~id:(`Int 2) ~params:(stdio_modern_params ~version:"2099-01-01" ()) "server/discover"
      ; stdio_request ~params:listen "subscriptions/listen"
      ; stdio_request ~id:`Null ~params:listen "subscriptions/listen"
      ; stdio_request ~id:(`Bool true) ~params:listen "subscriptions/listen"
      ; stdio_request ~id:(`Int 3) ~params:listen "subscriptions/listen"
      ; malformed_cancel
      ; stdio_request ~params:(`Assoc [ "requestId", `Int 3; "reason", `Int 42 ]) "notifications/cancelled"
      ; stdio_request ~params:(`Assoc [ "requestId", `Int 3; "requestId", `Int 3 ]) "notifications/cancelled"
      ; stdio_request ~id:(`Int 3) ~params:modern "server/discover"
      ; stdio_request ~params:cancelled "notifications/cancelled"
      ; stdio_request ~id:(`Int 3) ~params:modern "server/discover"
      ; stdio_request ~id:(`Int 4) ~params:initialize "initialize"
      ; stdio_request "notifications/initialized"
      ; stdio_request ~id:(`Int 5) "unknown/method"
      ; stdio_request ~id:(`Int 6) ~params:modern "resources/subscribe"
      ] in
    let nth = List.nth responses in
    Alcotest.(check int) "only requests and acknowledgement produce messages" 11
      (List.length responses);
    Alcotest.(check int) "missing modern metadata" (-32602) (error_code_exn (nth 0));
    Alcotest.(check int) "unsupported modern version" (-32022) (error_code_exn (nth 1));
    Alcotest.(check bool) "unsupported version echoes request ID" true
      (Yojson.Safe.Util.member "id" (nth 1) = `Int 2);
    Alcotest.(check int) "null request ID is not a notification" (-32600) (error_code_exn (nth 2));
    Alcotest.(check int) "invalid request ID" (-32600) (error_code_exn (nth 3));
    Alcotest.(check bool) "subscription acknowledged" true
      (Yojson.Safe.Util.member "method" (nth 4) = `String "notifications/subscriptions/acknowledged");
    Alcotest.(check int) "malformed cancellation rejected" (-32600) (error_code_exn (nth 5));
    Alcotest.(check int) "active subscription ID is not reused" (-32600) (error_code_exn (nth 6));
    Alcotest.(check bool) "duplicate error cannot end active subscription" true
      (Yojson.Safe.Util.member "id" (nth 6) = `Null);
    Alcotest.(check bool) "cancel frees ID without sending a response" true
      (Yojson.Safe.Util.member "id" (nth 7) = `Int 3
       && Yojson.Safe.Util.member "result" (nth 7) <> `Null);
    Alcotest.(check bool) "initialize counter-offers legacy" true
      (Yojson.Safe.Util.(member "protocolVersion" (member "result" (nth 8))) = `String "2025-11-25");
    Alcotest.(check int) "legacy request reaches dispatcher" (-32601) (error_code_exn (nth 9));
    Alcotest.(check int) "removed 2026 method rejected" (-32601) (error_code_exn (nth 10));
    Alcotest.(check int) "no subscription remains after EOF" 0 (Mcp_subscriptions.count ()))

(* A stdio server whose tools/call parks until [release] resolves; every other
   request takes the real handler. [run_stdio_messages] sends one message and
   reads its answer before the next, so it cannot show a ping answered while a
   call is in flight. [with_concurrent_stdio] writes without waiting. *)
let parked_tool_call ~release ~on_enter ~on_cancel ~clock ~sw ~mcp_session_id state request =
  let json = Yojson.Safe.from_string request in
  match Yojson.Safe.Util.member "method" json with
  | `String "tools/call" ->
    on_enter ();
    (try Eio.Promise.await release
     with Eio.Cancel.Cancelled _ as exn -> on_cancel (); raise exn);
    `Assoc
      [ "jsonrpc", `String "2.0"
      ; "id", Yojson.Safe.Util.member "id" json
      ; "result", `Assoc [] ]
  | _ -> Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ?mcp_session_id state request

(* A legacy session, so a legacy [ping] (no [_meta]) is admitted and answers
   with a result. *)
let stdio_legacy_initialize_params =
  `Assoc
    [ "protocolVersion", `String "2025-11-25"
    ; "capabilities", `Assoc []
    ; "clientInfo", `Assoc [ "name", `String "test"; "version", `String "1" ] ]

let with_concurrent_stdio ~clock ~sw ~handle_request state f =
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  let input, input_writer = Eio_unix.pipe sw in
  let output, output_writer = Eio_unix.pipe sw in
  let env = object
    method clock = clock
    method stdin = input
    method stdout = output_writer
  end in
  let finished, finish = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Flow.close output_writer; Eio.Promise.resolve finish ())
      (fun () -> Masc.Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env state));
  let reader = Eio.Buf_read.of_flow output ~max_size:(1024 * 1024) in
  let input_open = ref true in
  let close_input () =
    if !input_open then (input_open := false; Eio.Flow.close input_writer) in
  let send message =
    Eio.Flow.copy_string (Yojson.Safe.to_string message ^ "\n") input_writer in
  let read_response () =
    Eio.Time.with_timeout_exn clock 5. (fun () ->
      Yojson.Safe.from_string (Eio.Buf_read.line reader)) in
  Fun.protect
    ~finally:(fun () -> close_input (); if not was_ready then Eio_guard.disable ())
    (fun () ->
      f ~send ~read_response;
      close_input ();
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished);
      (match Eio.Buf_read.line reader with
       | exception End_of_file -> ()
       | _ -> Alcotest.fail "unexpected trailing stdio response"))

let test_stdio_ping_is_answered_during_a_long_tool_call () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let modern = stdio_modern_params () in
    let release, resolve_release = Eio.Promise.create () in
    let entered, resolve_entered = Eio.Promise.create () in
    let handle_request =
      parked_tool_call ~release
        ~on_enter:(fun () -> Eio.Promise.resolve resolve_entered ())
        ~on_cancel:(fun () -> ()) in
    with_concurrent_stdio ~clock ~sw ~handle_request state (fun ~send ~read_response ->
      send (stdio_request ~id:(`Int 10) ~params:stdio_legacy_initialize_params "initialize");
      let opened = read_response () in
      Alcotest.(check bool) "the legacy session opens" true
        (Yojson.Safe.Util.member "id" opened = `Int 10
         && Yojson.Safe.Util.member "error" opened = `Null);
      send (stdio_request ~id:(`Int 1) ~params:modern "tools/call");
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await entered);
      send (stdio_request ~id:(`Int 2) "ping");
      let ping = read_response () in
      Alcotest.(check bool) "ping is answered with its result while the call is parked" true
        (Yojson.Safe.Util.member "id" ping = `Int 2
         && Yojson.Safe.Util.member "result" ping = `Assoc []);
      Eio.Promise.resolve resolve_release ();
      let call = read_response () in
      Alcotest.(check bool) "the call answers once released" true
        (Yojson.Safe.Util.member "id" call = `Int 1)))

let test_stdio_cancellation_stops_a_running_tool_call () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let modern = stdio_modern_params () in
    let release, _ = Eio.Promise.create () in
    let entered, resolve_entered = Eio.Promise.create () in
    let cancelled, resolve_cancelled = Eio.Promise.create () in
    let handle_request =
      parked_tool_call ~release
        ~on_enter:(fun () -> Eio.Promise.resolve resolve_entered ())
        ~on_cancel:(fun () -> Eio.Promise.resolve resolve_cancelled ()) in
    with_concurrent_stdio ~clock ~sw ~handle_request state (fun ~send ~read_response ->
      send (stdio_request ~id:(`Int 10) ~params:stdio_legacy_initialize_params "initialize");
      let opened = read_response () in
      Alcotest.(check bool) "the legacy session opens" true
        (Yojson.Safe.Util.member "id" opened = `Int 10
         && Yojson.Safe.Util.member "error" opened = `Null);
      send (stdio_request ~id:(`Int 1) ~params:modern "tools/call");
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await entered);
      send (stdio_request ~params:(`Assoc [ "requestId", `Int 1 ]) "notifications/cancelled");
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await cancelled);
      send (stdio_request ~id:(`Int 2) "ping");
      let next = read_response () in
      Alcotest.(check bool) "the cancelled call wrote nothing and the loop still answers" true
        (Yojson.Safe.Util.member "id" next = `Int 2
         && Yojson.Safe.Util.member "result" next = `Assoc [])))

(* A sink that pauses either before or after its first byte. In both cases the
   response has committed under the output lock; the second response is still
   waiting for that lock. No wall-clock delay decides the ordering. *)
module Stdio_partial_sink = struct
  type t =
    { output : Buffer.t
    ; first_byte : unit Eio.Promise.u
    ; release : unit Eio.Promise.t
    ; write_first_byte : bool
    ; mutable began : bool
    }

  let single_write t bufs =
    let bytes = String.concat "" (List.map Cstruct.to_string bufs) in
    if not t.began then (
      t.began <- true;
      Eio.Promise.resolve t.first_byte ();
      if t.write_first_byte then (Buffer.add_char t.output bytes.[0]; 1)
      else (
        Eio.Promise.await t.release;
        Buffer.add_string t.output bytes;
        String.length bytes))
    else (
      Eio.Promise.await t.release;
      Buffer.add_string t.output bytes;
      String.length bytes)

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
end

let test_stdio_requires_enabled_guard () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let was_ready = Eio_guard.is_ready () in
  Fun.protect
    ~finally:(fun () ->
      if was_ready then Eio_guard.enable () else Eio_guard.disable ();
      cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      Eio_guard.disable ();
      let handle_request ~clock:_ ~sw:_ ~mcp_session_id:_ _ _ =
        Alcotest.fail "request handler must not run" in
      Alcotest.check_raises "guard checked before reading stdin"
        (Invalid_argument "run_stdio requires Eio_guard.enable () for its entire lifetime")
        (fun () -> Masc.Mcp_server_eio_protocol.run_stdio
          ~handle_request ~sw ~env state))

let test_stdio_eof_drains_committed_response () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let was_ready = Eio_guard.is_ready () in
    Fun.protect ~finally:(fun () -> if was_ready then Eio_guard.enable () else Eio_guard.disable ()) (fun () ->
      Eio_guard.enable ();
        List.iter (fun (framed, write_first_byte) ->
        let input, input_writer = Eio_unix.pipe sw in
        let first_byte, signal_first = Eio.Promise.create () in
        let release, signal_release = Eio.Promise.create () in
        let parked, signal_parked = Eio.Promise.create () in
        let waiting_output, signal_waiting_output = Eio.Promise.create () in
        let cancelled, signal_cancelled = Eio.Promise.create () in
        let finished, signal_finished = Eio.Promise.create () in
        let output = Buffer.create 128 in
        let sink_state : Stdio_partial_sink.t =
          { output; first_byte = signal_first; release; write_first_byte; began = false } in
        let stdout = Eio.Resource.T (sink_state, Eio.Flow.Pi.sink (module Stdio_partial_sink)) in
        let stdio_env = object
          method clock = clock
          method stdin = input
          method stdout = stdout
        end in
        let response = `Assoc
          [ "jsonrpc", `String "2.0"; "id", `Int 1; "result", `Assoc [] ] in
        let handle_request ~clock:_ ~sw:_ ~mcp_session_id:_ _state request =
          let id = Yojson.Safe.Util.member "id" (Yojson.Safe.from_string request) in
          match id with
          | `Int 1 -> response
          | `Int 3 ->
            Eio.Promise.resolve signal_waiting_output ();
            `Assoc [ "jsonrpc", `String "2.0"; "id", `Int 3; "result", `Assoc [] ]
          | `Int 2 ->
            Eio.Promise.resolve signal_parked ();
            (try Eio.Promise.await (fst (Eio.Promise.create ())) with
             | Eio.Cancel.Cancelled _ as exn ->
               Eio.Promise.resolve signal_cancelled ();
               raise exn)
          | _ -> Alcotest.fail "unexpected test request" in
        Eio.Fiber.fork ~sw (fun () ->
          Fun.protect ~finally:(fun () -> Eio.Promise.resolve signal_finished ())
            (fun () -> Masc.Mcp_server_eio_protocol.run_stdio
              ~handle_request ~sw ~env:stdio_env state));
        let send id =
          let request = stdio_request ~id:(`Int id) ~params:(stdio_modern_params ()) "tools/call"
            |> Yojson.Safe.to_string in
          let message = if framed then
              Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length request) request
            else request ^ "\n" in
          Eio.Flow.copy_string message input_writer in
        send 1;
        Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await first_byte);
        (* This handler is done, but its response is waiting for the first
           writer's output lock and has not committed. *)
        send 3;
        Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await waiting_output);
        send 2;
        Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await parked);
        Eio.Flow.close input_writer;
        Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await cancelled);
        Alcotest.(check bool) "committed output keeps shutdown pending" false
          (Eio.Promise.is_resolved finished);
        Eio.Promise.resolve signal_release ();
        Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished);
        let body = Yojson.Safe.to_string response in
        let expected = if framed then
            Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length body) body
          else body ^ "\n" in
        Alcotest.(check string) "committed response is whole; parked call emits nothing"
          expected (Buffer.contents output))
        [ false, false; false, true; true, false; true, true ]))

(* A sink that fails once after accepting one byte, but would accept later
   writes. This detects attempts to append a second frame after corruption. *)
module Stdio_failing_sink = struct
  type t =
    { output : Buffer.t
    ; first_byte : unit Eio.Promise.u
    ; fail_now : unit Eio.Promise.t
    ; mutable writes : int
    }

  let single_write t bufs =
    let bytes = String.concat "" (List.map Cstruct.to_string bufs) in
    t.writes <- t.writes + 1;
    match t.writes with
    | 1 ->
      Buffer.add_char t.output bytes.[0];
      Eio.Promise.resolve t.first_byte ();
      1
    | 2 -> Eio.Promise.await t.fail_now; failwith "injected stdout failure"
    | _ -> Buffer.add_string t.output bytes; String.length bytes

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
end

let test_stdio_write_failure_never_appends_another_frame () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let was_ready = Eio_guard.is_ready () in
    Eio_guard.enable ();
    Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
      List.iter (fun (framed, synchronous) ->
        let input, input_writer = Eio_unix.pipe sw in
        let started, signal_started = Eio.Promise.create () in
        let fail_now, signal_failure = Eio.Promise.create () in
        let second, signal_second = Eio.Promise.create () in
        let finished, signal_finished = Eio.Promise.create () in
        let output = Buffer.create 128 in
        let sink_state : Stdio_failing_sink.t =
          { output; first_byte = signal_started; fail_now; writes = 0 } in
        let stdout = Eio.Resource.T (sink_state, Eio.Flow.Pi.sink (module Stdio_failing_sink)) in
        let stdio_env = object
          method clock = clock
          method stdin = input
          method stdout = stdout
        end in
        let handle_request ~clock:_ ~sw:_ ~mcp_session_id:_ _state request =
          let id = Yojson.Safe.Util.member "id" (Yojson.Safe.from_string request) in
          if id = `Int 2 then Eio.Promise.resolve signal_second ();
          `Assoc [ "jsonrpc", `String "2.0"; "id", id; "result", `Assoc [] ] in
        Eio.Fiber.fork ~sw (fun () ->
          let error =
            try Masc.Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env:stdio_env state; None
            with Eio.Cancel.Cancelled _ as exn -> raise exn | exn -> Some exn in
          Eio.Promise.resolve signal_finished error);
        let send id =
          let method_ = if synchronous then "server/discover" else "tools/call" in
          let request = stdio_request ~id:(`Int id) ~params:(stdio_modern_params ()) method_
            |> Yojson.Safe.to_string in
          let message = if framed then
              Printf.sprintf "Content-Length: %d\r\n\r\n%s" (String.length request) request
            else request ^ "\n" in
          Eio.Flow.copy_string message input_writer in
        send 1;
        Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await started);
        if not synchronous then (
          send 2;
          Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await second));
        Eio.Promise.resolve signal_failure ();
        let error = Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished) in
        Eio.Flow.close input_writer;
        let rec contains_sink_failure = function
          | Failure message -> String.equal message "injected stdout failure"
          | Eio.Exn.Multiple failures -> List.exists (fun (exn, _) -> contains_sink_failure exn) failures
          | _ -> false in
        Alcotest.(check bool) "transport retains the original sink failure" true
          (Option.fold ~none:false ~some:contains_sink_failure error);
        Alcotest.(check int) "no later sink write was attempted" 2 sink_state.writes;
        Alcotest.(check int) "no second frame was appended" 1 (Buffer.length output))
        [ false, false; false, true; true, false; true, true ]))

(* The acknowledgement goes through first. Once armed, a notification writes
   one byte and blocks, modelling a publisher owned by another request fiber. *)
module Stdio_subscription_sink = struct
  type t =
    { output : Buffer.t
    ; acknowledged : unit Eio.Promise.u
    ; notification_started : unit Eio.Promise.u
    ; release : unit Eio.Promise.t
    ; fail_after_release : bool
    ; armed : bool Atomic.t
    ; mutable began : bool
    }

  let single_write t bufs =
    let bytes = String.concat "" (List.map Cstruct.to_string bufs) in
    if not (Atomic.get t.armed) then (
      Buffer.add_string t.output bytes;
      if String.contains bytes '\n' then ignore (Eio.Promise.try_resolve t.acknowledged ());
      String.length bytes)
    else if not t.began then (
      t.began <- true;
      Buffer.add_char t.output bytes.[0];
      Eio.Promise.resolve t.notification_started ();
      1)
    else (
      Eio.Promise.await t.release;
      if t.fail_after_release then failwith "injected subscription stdout failure";
      Buffer.add_string t.output bytes;
      String.length bytes)

  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
end

exception Test_stdio_parent_cancel

let test_stdio_parent_cancel_drains_external_subscription_send () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let was_ready = Eio_guard.is_ready () in
    Fun.protect ~finally:(fun () -> if was_ready then Eio_guard.enable () else Eio_guard.disable ()) (fun () ->
      Eio_guard.enable ();
      let other_deliveries = Atomic.make 0 in
      let filter = { Mcp_transport_protocol.empty_subscription_filter with tools_list_changed = true } in
      let other = Mcp_subscriptions.register ~subscription_id:(`Int 43) ~filter
          ~send:(fun _ -> ignore (Atomic.fetch_and_add other_deliveries 1); true) in
      Fun.protect ~finally:(fun () -> Mcp_subscriptions.unregister other) (fun () ->
      let before = Mcp_subscriptions.count () in
      let input, input_writer = Eio_unix.pipe sw in
      let ack, signal_ack = Eio.Promise.create () in
      let started, signal_started = Eio.Promise.create () in
      let never_release, _ = Eio.Promise.create () in
      let owner, signal_owner = Eio.Promise.create () in
      let stopped, signal_stopped = Eio.Promise.create () in
      let published, signal_published = Eio.Promise.create () in
      let sink_state : Stdio_subscription_sink.t =
        { output = Buffer.create 128; acknowledged = signal_ack;
          notification_started = signal_started; release = never_release;
          fail_after_release = false; armed = Atomic.make false; began = false } in
      let stdout = Eio.Resource.T (sink_state, Eio.Flow.Pi.sink (module Stdio_subscription_sink)) in
      let stdio_env = object
        method clock = clock
        method stdin = input
        method stdout = stdout
      end in
      let handle_request ~clock ~sw ~mcp_session_id state request =
        Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ?mcp_session_id state request in
      Eio.Fiber.fork ~sw (fun () ->
        let cancelled =
          try Eio.Cancel.sub (fun context ->
            Eio.Promise.resolve signal_owner context;
            Masc.Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env:stdio_env state);
            false
          with Eio.Cancel.Cancelled Test_stdio_parent_cancel -> true in
        Eio.Promise.resolve signal_stopped cancelled);
      let params = match stdio_modern_params () with
        | `Assoc fields -> `Assoc (("notifications", `Assoc [ "toolsListChanged", `Bool true ]) :: fields)
        | _ -> assert false in
      let request = stdio_request ~id:(`Int 42) ~params "subscriptions/listen" in
      Eio.Flow.copy_string (Yojson.Safe.to_string request ^ "\n") input_writer;
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await ack);
      Atomic.set sink_state.armed true;
      let owner_domain = Domain.self () in
      Eio.Fiber.fork ~sw (fun () ->
        let ran_elsewhere = Eio.Domain_manager.run (Eio.Stdenv.domain_mgr env) (fun () ->
          let ran_elsewhere = Domain.self () <> owner_domain in
          Mcp_subscriptions.notify_tools_list_changed (`Assoc []);
          ran_elsewhere) in
        Eio.Promise.resolve signal_published ran_elsewhere);
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await started);
      Eio.Flow.close input_writer;
      let rec wait_until_retired () =
        if Mcp_subscriptions.count () <> before then (Eio.Fiber.yield (); wait_until_retired ()) in
      Eio.Time.with_timeout_exn clock 5. wait_until_retired;
      Alcotest.(check bool) "EOF waits for the committed external send" false
        (Eio.Promise.is_resolved stopped);
      Eio.Cancel.cancel (Eio.Promise.await owner) Test_stdio_parent_cancel;
      let cancelled = Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await stopped) in
      Alcotest.(check bool) "original parent cancellation propagates" true cancelled;
      let ran_elsewhere = Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await published) in
      Alcotest.(check bool) "publisher ran on another domain" true ran_elsewhere;
      Alcotest.(check int) "other subscribers still receive the event" 1 (Atomic.get other_deliveries);
      Alcotest.(check int) "the subscriber is retired and drained" before (Mcp_subscriptions.count ())))
      )

exception Test_stdio_earlier_cancel

module Stdio_early_failure_source = struct
  type t =
    { request : string
    ; fail_now : unit Eio.Promise.t
    ; waiting : unit Eio.Promise.u
    ; mutable offset : int
    }

  let read_methods = []
  let single_read t target =
    let remaining = String.length t.request - t.offset in
    if remaining > 0 then (
      let n = min remaining (Cstruct.length target) in
      Cstruct.blit_from_string t.request t.offset target 0 n;
      t.offset <- t.offset + n;
      n)
    else (
      ignore (Eio.Promise.try_resolve t.waiting ());
      Eio.Promise.await t.fail_now;
      raise (Eio.Cancel.Cancelled Test_stdio_earlier_cancel))
end

let test_stdio_prior_failure_precedes_drain_cancellation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let was_ready = Eio_guard.is_ready () in
    Eio_guard.enable ();
    Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
      let before = Mcp_subscriptions.count () in
      let params = match stdio_modern_params () with
        | `Assoc fields -> `Assoc (("notifications", `Assoc [ "toolsListChanged", `Bool true ]) :: fields)
        | _ -> assert false in
      let request = stdio_request ~id:(`Int 42) ~params "subscriptions/listen"
        |> Yojson.Safe.to_string in
      let fail_now, signal_failure = Eio.Promise.create () in
      let waiting, signal_waiting = Eio.Promise.create () in
      let source : Stdio_early_failure_source.t =
        { request = request ^ "\n"; fail_now; waiting = signal_waiting; offset = 0 } in
      let stdin = Eio.Resource.T (source, Eio.Flow.Pi.source (module Stdio_early_failure_source)) in
      let ack, signal_ack = Eio.Promise.create () in
      let started, signal_started = Eio.Promise.create () in
      let never_release, _ = Eio.Promise.create () in
      let owner, signal_owner = Eio.Promise.create () in
      let finished, signal_finished = Eio.Promise.create () in
      let published, signal_published = Eio.Promise.create () in
      let sink : Stdio_subscription_sink.t =
        { output = Buffer.create 128; acknowledged = signal_ack;
          notification_started = signal_started; release = never_release;
          fail_after_release = false; armed = Atomic.make false; began = false } in
      let stdout = Eio.Resource.T (sink, Eio.Flow.Pi.sink (module Stdio_subscription_sink)) in
      let stdio_env = object
        method clock = clock
        method stdin = stdin
        method stdout = stdout
      end in
      let handle_request ~clock ~sw ~mcp_session_id state request =
        Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ?mcp_session_id state request in
      Eio.Fiber.fork ~sw (fun () ->
        let error =
          try Eio.Cancel.sub (fun context ->
            Eio.Promise.resolve signal_owner context;
            Masc.Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env:stdio_env state); None
          with exn -> Some exn in
        Eio.Promise.resolve signal_finished error);
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await ack);
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await waiting);
      Atomic.set sink.armed true;
      Eio.Fiber.fork ~sw (fun () ->
        Mcp_subscriptions.notify_tools_list_changed (`Assoc []);
        Eio.Promise.resolve signal_published ());
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await started);
      Eio.Promise.resolve signal_failure ();
      let rec wait_until_retired () =
        if Mcp_subscriptions.count () <> before then (Eio.Fiber.yield (); wait_until_retired ()) in
      Eio.Time.with_timeout_exn clock 5. wait_until_retired;
      Eio.Cancel.cancel (Eio.Promise.await owner) Test_stdio_parent_cancel;
      let error = Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished) in
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await published);
      Alcotest.(check bool) "earlier failure takes precedence over drain cancellation" true
        (match error with Some (Eio.Cancel.Cancelled Test_stdio_earlier_cancel) -> true
         | Some _ | None -> false)))

let test_stdio_eof_reports_external_send_failure () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let was_ready = Eio_guard.is_ready () in
    Eio_guard.enable ();
    Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
      let before = Mcp_subscriptions.count () in
      let input, input_writer = Eio_unix.pipe sw in
      let ack, signal_ack = Eio.Promise.create () in
      let started, signal_started = Eio.Promise.create () in
      let release, signal_release = Eio.Promise.create () in
      let finished, signal_finished = Eio.Promise.create () in
      let published, signal_published = Eio.Promise.create () in
      let sink_state : Stdio_subscription_sink.t =
        { output = Buffer.create 128; acknowledged = signal_ack;
          notification_started = signal_started; release;
          fail_after_release = true; armed = Atomic.make false; began = false } in
      let stdout = Eio.Resource.T (sink_state, Eio.Flow.Pi.sink (module Stdio_subscription_sink)) in
      let stdio_env = object
        method clock = clock
        method stdin = input
        method stdout = stdout
      end in
      let handle_request ~clock ~sw ~mcp_session_id state request =
        Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ?mcp_session_id state request in
      Eio.Fiber.fork ~sw (fun () ->
        let error =
          try Masc.Mcp_server_eio_protocol.run_stdio ~handle_request ~sw ~env:stdio_env state; None
          with Eio.Cancel.Cancelled _ as exn -> raise exn | exn -> Some exn in
        Eio.Promise.resolve signal_finished error);
      let params = match stdio_modern_params () with
        | `Assoc fields -> `Assoc (("notifications", `Assoc [ "toolsListChanged", `Bool true ]) :: fields)
        | _ -> assert false in
      let request = stdio_request ~id:(`Int 42) ~params "subscriptions/listen" in
      Eio.Flow.copy_string (Yojson.Safe.to_string request ^ "\n") input_writer;
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await ack);
      Atomic.set sink_state.armed true;
      Eio.Fiber.fork ~sw (fun () ->
        Mcp_subscriptions.notify_tools_list_changed (`Assoc []);
        Eio.Promise.resolve signal_published ());
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await started);
      Eio.Flow.close input_writer;
      let rec wait_until_retired () =
        if Mcp_subscriptions.count () <> before then (Eio.Fiber.yield (); wait_until_retired ()) in
      Eio.Time.with_timeout_exn clock 5. wait_until_retired;
      Eio.Promise.resolve signal_release ();
      let error = Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished) in
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await published);
      Alcotest.(check bool) "owner retains the original sink failure after EOF" true
        (match error with Some (Failure message) ->
           String.equal message "injected subscription stdout failure"
         | Some _ | None -> false)))

let test_subscription_retirement_keeps_drain_authority () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
    let before = Mcp_subscriptions.count () in
    let started, signal_started = Eio.Promise.create () in
    let release, signal_release = Eio.Promise.create () in
    let removed, signal_removed = Eio.Promise.create () in
    let owner_drained, signal_owner_drained = Eio.Promise.create () in
    let published, signal_published = Eio.Promise.create () in
    let filter = { Mcp_transport_protocol.empty_subscription_filter with tools_list_changed = true } in
    let token = Mcp_subscriptions.register ~subscription_id:(`Int 44) ~filter
        ~send:(fun _ -> Eio.Promise.resolve signal_started (); Eio.Promise.await release; true) in
    Eio.Fiber.fork ~sw (fun () ->
      Mcp_subscriptions.notify_tools_list_changed (`Assoc []);
      Eio.Promise.resolve signal_published ());
    Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await started);
    Eio.Fiber.fork ~sw (fun () ->
      Mcp_subscriptions.unregister token;
      Eio.Promise.resolve signal_removed ());
    let rec wait_until_removed () =
      if Mcp_subscriptions.count () <> before then (Eio.Fiber.yield (); wait_until_removed ()) in
    Eio.Time.with_timeout_exn clock 5. wait_until_removed;
    (* Another publisher already removed the registry entry. The owner token
       must still name the same send lock and not falsely report a drain. *)
    let retired = Mcp_subscriptions.retire token in
    Eio.Fiber.fork ~sw (fun () ->
      Mcp_subscriptions.await_retired retired;
      Eio.Promise.resolve signal_owner_drained ());
    Alcotest.(check bool) "owner drain waits for the removed entry" false
      (Eio.Promise.is_resolved owner_drained);
    Alcotest.(check bool) "other unregister also waits" false (Eio.Promise.is_resolved removed);
    Eio.Promise.resolve signal_release ();
    Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await owner_drained);
    Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await removed);
    Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await published);
    Alcotest.(check int) "entry remains absent" before (Mcp_subscriptions.count ()))

let test_stdio_subscription_requires_auth () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"test-admin");
    let messages = run_stdio_messages ~clock ~sw state
      [ stdio_request ~id:(`Int 7) ~params:(stdio_listen_params ()) "subscriptions/listen" ] in
    match messages with
    | [ response ] ->
      Alcotest.(check int) "authentication rejection" (-32001) (error_code_exn response);
      Alcotest.(check bool) "no subscription acknowledgement" true
        (Yojson.Safe.Util.member "method" response = `Null)
    | _ -> Alcotest.fail "expected only an authentication error")

let test_stdio_legacy_ping_and_modern_removal () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let initialize = `Assoc
      [ "protocolVersion", `String "2025-11-25"; "capabilities", `Assoc []
      ; "clientInfo", `Assoc [ "name", `String "test"; "version", `String "1" ] ] in
    let responses = run_stdio_messages ~clock ~sw state
      [ stdio_request ~id:(`Int 21) ~params:initialize "initialize"
      ; stdio_request ~id:(`Int 22) "ping"
      ; stdio_request "notifications/initialized"
      ; stdio_request ~id:(`Int 23) "ping"
      ; stdio_request ~id:(`Int 24) ~params:(stdio_modern_params ()) "ping"
      ; stdio_request ~id:(`Int 25) ~params:`Null "ping"
      ; stdio_request ~id:(`Int 26) ~params:(`List []) "ping"
      ; stdio_request ~id:(`Int 27) ~params:(`Bool true) "ping"
      ; stdio_request ~id:(`Int 28) ~params:(`Assoc [ "_meta", `Null ]) "ping"
      ; stdio_request ~id:(`Int 29) ~params:(`Assoc [ "_meta", `Assoc [ "progressToken", `Bool true ] ]) "ping"
      ; stdio_request ~id:(`Int 30) ~params:(`Assoc [ "_meta", `Assoc [ "progressToken", `String "p" ]; "extra", `Int 1 ]) "ping" ] in
    match responses with
    | [ _; before_ready; after_ready; modern; null_params; list_params; bool_params;
        bad_meta; bad_token; valid_meta ] ->
      List.iter2 (fun id response ->
        Alcotest.(check bool) "legacy ping returns an empty result with its ID" true
          (Yojson.Safe.Util.member "id" response = `Int id
           && Yojson.Safe.Util.member "result" response = `Assoc []))
        [ 22; 23 ] [ before_ready; after_ready ];
      Alcotest.(check int) "modern ping was removed" (-32601) (error_code_exn modern);
      Alcotest.(check bool) "modern error preserves ID" true
        (Yojson.Safe.Util.member "id" modern = `Int 24);
      List.iter2 (fun id response ->
        Alcotest.(check int) "invalid ping params rejected" (-32602) (error_code_exn response);
        Alcotest.(check bool) "ping error preserves ID" true
          (Yojson.Safe.Util.member "id" response = `Int id))
        [ 25; 26; 27; 28; 29 ] [ null_params; list_params; bool_params; bad_meta; bad_token ];
      Alcotest.(check bool) "legacy metadata and extensions are accepted" true
        (Yojson.Safe.Util.member "id" valid_meta = `Int 30
         && Yojson.Safe.Util.member "result" valid_meta = `Assoc [])
    | _ -> Alcotest.fail "expected initialize and nine ping responses")

let test_stdio_rejects_unissued_modern_continuations () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    Auth.disable_auth base_path;
    let params field name continuation =
      match stdio_modern_params () with
      | `Assoc fields -> `Assoc ((field, `String name) :: continuation :: fields)
      | _ -> assert false in
    let cases =
      [ 31, "tools/call", "name", "masc_status", ("requestState", `String "opaque")
      ; 32, "tools/call", "name", "masc_status", ("inputResponses", `Assoc [])
      ; 33, "resources/read", "uri", "masc://status", ("requestState", `String "opaque")
      ; 34, "resources/read", "uri", "masc://status", ("inputResponses", `Assoc [])
      ; 35, "prompts/get", "name", "tool_help", ("requestState", `String "opaque")
      ; 36, "prompts/get", "name", "tool_help", ("inputResponses", `Assoc []) ] in
    let messages = List.map (fun (id, method_, field, name, continuation) ->
      stdio_request ~id:(`Int id) ~params:(params field name continuation) method_) cases in
    let responses = run_stdio_messages ~clock ~sw state messages in
    Alcotest.(check int) "one error per request" (List.length cases) (List.length responses);
    List.iter2 (fun (id, _, _, _, _) response ->
      Alcotest.(check int) "unissued continuation is invalid" (-32602) (error_code_exn response);
      Alcotest.(check bool) "original ID is preserved" true
        (Yojson.Safe.Util.member "id" response = `Int id)) cases responses)

let test_stdio_modern_calls_do_not_reuse_legacy_identity () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    ignore (Masc.Workspace.init (Masc.Mcp_server.workspace_config state) ~agent_name:None);
    let before = Client_registry_eio.total_count () in
    let observed = ref [] in
    let on_handled session request _response =
      let method_ = Yojson.Safe.from_string request |> Yojson.Safe.Util.member "method" in
      let subscribed = match session with
        | None -> false
        | Some session_id ->
          Masc.Mcp_server_eio_protocol.For_testing.resource_is_subscribed
            ~session_id ~uri:"masc://status" in
      observed := (method_, session, Client_registry_eio.total_count (), subscribed) :: !observed
    in
    let modern_call arguments =
      match stdio_modern_params () with
      | `Assoc fields -> `Assoc (("name", `String "masc_status") :: ("arguments", arguments) :: fields)
      | _ -> assert false
    in
    let initialize = `Assoc
      [ "protocolVersion", `String "2025-11-25"; "capabilities", `Assoc []
      ; "clientInfo", `Assoc [ "name", `String "test"; "version", `String "1" ] ] in
    let uri = `Assoc [ "uri", `String "masc://status" ] in
    let responses = run_stdio_messages ~on_handled ~clock ~sw state
      [ stdio_request ~id:(`Int 1) ~params:(modern_call (`Assoc [ "_agent_name", `String "alice" ])) "tools/call"
      ; stdio_request ~id:(`Int 2) ~params:(modern_call (`Assoc [])) "tools/call"
      ; stdio_request ~id:(`Int 3) ~params:initialize "initialize"
      ; stdio_request "notifications/initialized"
      ; stdio_request ~id:(`Int 6) ~params:(`Assoc
          [ "name", `String "masc_status"; "arguments", `Assoc [ "_agent_name", `String "legacy-alice" ] ]) "tools/call"
      ; stdio_request ~id:(`Int 4) ~params:uri "resources/subscribe"
      ; stdio_request ~id:(`Int 5) ~params:uri "resources/unsubscribe"
      ; stdio_request ~id:(`Int 7) ~params:uri "resources/subscribe" ] in
    let seen = List.rev !observed in
    (match seen with
     | [ (`String "tools/call", None, count1, _); (`String "tools/call", None, count2, _)
       ; (`String "initialize", Some session1, _, _); (`String "notifications/initialized", Some session2, _, _)
       ; (`String "tools/call", Some session3, legacy_count, _)
       ; (`String "resources/subscribe", Some session4, _, true)
       ; (`String "resources/unsubscribe", Some session5, _, false)
       ; (`String "resources/subscribe", Some session6, _, true) ] ->
       Alcotest.(check int) "first modern call does not cache its caller" before count1;
       Alcotest.(check int) "second modern call has no prior caller cache" before count2;
       Alcotest.(check int) "legacy call registered an identity" (before + 1) legacy_count;
       Alcotest.(check bool) "legacy lifecycle keeps one connection session" true
         (String.equal session1 session2 && String.equal session2 session3 && String.equal session3 session4
          && String.equal session4 session5 && String.equal session5 session6);
       Alcotest.(check bool) "stdio EOF removes the remaining legacy subscription" false
         (Masc.Mcp_server_eio_protocol.For_testing.resource_is_subscribed
            ~session_id:session1 ~uri:"masc://status")
     | _ -> Alcotest.fail "unexpected modern or legacy session admission");
    Alcotest.(check int) "all requests returned one response" 7 (List.length responses);
    List.iter (fun response ->
      Alcotest.(check bool) "tool and legacy subscription requests reached their handler" true
        (Yojson.Safe.Util.member "result" response <> `Null)) responses;
    Alcotest.(check int) "stdio EOF removed legacy identity" before (Client_registry_eio.total_count ()))

let test_stdio_forwards_external_credential () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  Fun.protect ~finally:(fun () ->
    if not was_ready then Eio_guard.disable ();
    cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"test-admin");
    let token = match Auth.create_token base_path ~agent_name:"stdio-client" ~role:Masc_domain.Worker with
      | Ok (token, _) -> token
      | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error) in
    let player = match Auth.create_token base_path ~agent_name:"stdio-player" ~role:Masc_domain.Player with
      | Ok (token, _) -> token
      | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error) in
    let execute ?auth_token () =
      let input, input_writer = Eio_unix.pipe sw in
      let output, output_writer = Eio_unix.pipe sw in
      let stdio_env : Eio_unix.Stdenv.base = object
        method stdin = input
        method stdout = output_writer
        method stderr = env#stderr
        method net = env#net
        method domain_mgr = env#domain_mgr
        method process_mgr = env#process_mgr
        method clock = env#clock
        method mono_clock = env#mono_clock
        method fs = env#fs
        method cwd = env#cwd
        method secure_random = env#secure_random
        method debug = env#debug
        method backend_id = env#backend_id
      end in
      let finished, finish = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
        Fun.protect
          ~finally:(fun () -> Eio.Flow.close output_writer; Eio.Promise.resolve finish ())
          (fun () -> Mcp_eio.run_stdio ?auth_token ~sw ~env:stdio_env state));
      let request = stdio_request ~id:(`Int 10) ~params:(stdio_modern_params ()) "resources/list" in
      Eio.Flow.copy_string (Yojson.Safe.to_string request ^ "\n") input_writer;
      Eio.Flow.close input_writer;
      let response = Eio.Buf_read.of_flow output ~max_size:(1024 * 1024) |> Eio.Buf_read.line in
      Eio.Promise.await finished;
      Yojson.Safe.from_string response
    in
    Alcotest.(check int) "missing credential rejected" (-32001) (error_code_exn (execute ()));
    Alcotest.(check int) "invalid credential rejected" (-32001)
      (error_code_exn (execute ~auth_token:"invalid" ()));
    Alcotest.(check int) "player cannot read full workspace resources" (-32001)
      (error_code_exn (execute ~auth_token:player ()));
    (* Stdio sends no x-masc-keeper-name, so its door refuses the internal
       Keeper token, as the credential lookup refused it before the door. *)
    let internal = Auth.ensure_internal_keeper_token base_path in
    Alcotest.(check int) "the internal Keeper token is refused on stdio" (-32001)
      (error_code_exn (execute ~auth_token:internal ()));
    Alcotest.(check bool) "explicit caller credential admitted" true
      (Yojson.Safe.Util.member "result" (execute ~auth_token:token ()) <> `Null))

let test_handle_request_tools_list () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
    "contains masc_board_search (public surface)"
    true
    (List.mem "masc_board_search" names);
  Alcotest.(check bool)
    "contains masc_task_history (public surface)"
    true
    (List.mem "masc_task_history" names);
  Alcotest.(check bool)
    "contains masc_keeper_delegate_status (public surface)"
    true
    (List.mem "masc_keeper_delegate_status" names);
  Alcotest.(check bool)
    "contains masc_keeper_msg (public surface)"
    true
    (List.mem "masc_keeper_msg" names);
  Alcotest.(check bool)
    "omits masc_fusion_status (keeper-internal, RFC-0266)"
    false
    (List.mem "masc_fusion_status" names);
  Alcotest.(check bool)
    "removed experiment_start absent from list"
    false
    (List.mem "experiment_start" names);
  Alcotest.(check bool)
    "named workspace list hidden from list"
    false
    (List.mem "masc_workspaces_list" names);
  Alcotest.(check bool)
    "named workspace create hidden from list"
    false
    (List.mem "masc_workspace_create" names);
  Alcotest.(check bool)
    "named workspace enter hidden from list"
    false
    (List.mem "masc_workspace_enter" names);
  Alcotest.(check bool)
    "removed ghost tool absent from list"
    false
    (List.mem "masc_post_create" names);
  Alcotest.(check bool) "first page non-empty" true (names <> []);
  let meta = tools_list_meta_exn first_page in
  let total_count = int_field_exn "tools/list _meta" meta "totalCount" in
  let page_size = int_field_exn "tools/list _meta" meta "pageSize" in
  let result_fields = result_fields_exn first_page in
  Alcotest.(check (option int)) "tools/list ttlMs"
    (Some 5000)
    (match List.assoc_opt "ttlMs" result_fields with
     | Some (`Int value) -> Some value
     | _ -> None);
  Alcotest.(check (option string)) "tools/list cacheScope"
    (Some "private")
    (match List.assoc_opt "cacheScope" result_fields with
     | Some (`String value) -> Some value
     | _ -> None);
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~profile:Mcp_eio.Operator_remote state request
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
              (String_util.contains_substring instructions "six operator tools");
            Alcotest.(check bool) "does not mention surface audit" false
              (String_util.contains_substring instructions "surface audit");
            Alcotest.(check bool) "mentions confirm workflow" true
              (String_util.contains_substring instructions "confirm_required=true")
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_tools_list_operator_profile () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 12);
    ("method", `String "tools/list");
    ("params", `Assoc []);
  ]) in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~profile:Mcp_eio.Operator_remote state request
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
                     "masc_operator_board_attention_quarantine_requeue";
                     "masc_operator_confirm";
                     "masc_operator_digest";
                     "masc_operator_snapshot";
                     "masc_operator_task_recovery_resolve";
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
                 (* The tool icon was derived from the read-only capability
                    asserted two lines down, so it shipped no information the
                    same object did not already carry. *)
                 Alcotest.(check bool) "snapshot carries no derived icon" true
                   (Yojson.Safe.Util.member "icons" snapshot_tool = `Null);
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
                 (* Subjective open-world/destructive hints are omitted; the
                    profile exposes only objective typed metadata. *)
                 Alcotest.(check bool) "snapshot omits openWorld hint" true
                   (snapshot_tool |> Yojson.Safe.Util.member "annotations"
                    |> Yojson.Safe.Util.member "openWorldHint" = `Null);
                 Alcotest.(check bool) "digest omits openWorld hint" true
                   (digest_tool |> Yojson.Safe.Util.member "annotations"
                    |> Yojson.Safe.Util.member "openWorldHint" = `Null)
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~profile:Mcp_eio.Managed_agent state request
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
              (String_util.contains_substring instructions "managed-agent profile");
            Alcotest.(check bool) "distinguishes public inventory" true
              (String_util.contains_substring instructions "public /mcp surface")
        | _ -> Alcotest.fail "result not an object")
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_tools_list_managed_profile () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 112);
    ("method", `String "tools/list");
    ("params", `Assoc []);
  ]) in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~profile:Mcp_eio.Managed_agent state request
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
                 Alcotest.(check bool) "has canonical managed status" true
                   (List.mem "masc_status" names);
                 Alcotest.(check bool) "has canonical managed tasks" true
                   (List.mem "masc_tasks" names);
                 Alcotest.(check bool) "has canonical managed transition" true
                   (List.mem "masc_transition" names);
                 Alcotest.(check bool) "omits managed project status alias" false
                   (List.mem "masc_workspace_status" names);
                 Alcotest.(check bool) "omits managed list tasks alias" false
                   (List.mem "masc_list_tasks" names);
                 Alcotest.(check bool) "omits managed release alias" false
                   (List.mem "masc_release_task" names);
                 Alcotest.(check bool) "omits managed cancel alias" false
                   (List.mem "masc_cancel_task" names);
                 Alcotest.(check bool) "hides managed claim alias" false
                   (List.mem "masc_claim_task" names);
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

let test_handle_request_tools_call_managed_profile_rejects_hidden_claim_alias () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let sid = "mcp-managed-alias-claim" in
  let init_result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:Masc_test_deps.no_bearer
      ~mcp_session_id:sid state
      ~name:"masc_init" ~arguments:(`Assoc [])
  in
  (* masc_init and setup join are not under test here; initialise the workspace
     fixture directly so downstream managed-profile assertions are isolated. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false (Tool_result.is_success init_result);
  let _ = Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None in
  let _bound =
    Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"codex" ~capabilities:[] ()
  in
  let _added =
    Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"managed-claim"
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
  let metric_name = Otel_genai.Mcp_metric_name.server_operation_duration in
  let labels =
    [
      Otel_genai.Mcp_attr_key.mcp_method_name,
      Otel_genai.Mcp_value.tools_call_method;
      Otel_genai.Attr_key.gen_ai_operation_name, "execute_tool";
      Otel_genai.Attr_key.gen_ai_tool_name, "masc_claim_task";
      Otel_genai.Mcp_attr_key.mcp_protocol_version, "2025-06-18";
      Otel_genai.Mcp_attr_key.network_protocol_name, "http";
      Otel_genai.Mcp_attr_key.network_protocol_version, "2";
      Otel_genai.Mcp_attr_key.network_transport, "tcp";
      Otel_genai.Mcp_attr_key.error_type, Otel_genai.Mcp_value.tool_error_type;
    ]
  in
  let before_count =
    Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
  in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~profile:Mcp_eio.Managed_agent
      ~mcp_session_id:sid
      ~otel_mcp_protocol_version:"2025-06-18"
      ~otel_transport_context:(Otel_dispatch_hook.http_transport_context ~protocol_version:"2")
      state request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "removed alias rejected" true
    (String_util.contains_substring response_text
       "Tool 'masc_claim_task' is not available on this MCP endpoint");
  Alcotest.(check (float 0.0001)) "rejected tools/call records duration count"
    1.0
    (Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
     -. before_count);
  cleanup_dir base_path

let test_handle_request_tools_call_missing_params_records_duration () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let sid = "mcp-missing-params-duration" in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int 114
        ; "method", `String "tools/call"
        ])
  in
  let metric_name = Otel_genai.Mcp_metric_name.server_operation_duration in
  let labels =
    [ Otel_genai.Mcp_attr_key.mcp_method_name, Otel_genai.Mcp_value.tools_call_method
    ; Otel_genai.Attr_key.gen_ai_operation_name, "execute_tool"
    ; Otel_genai.Mcp_attr_key.mcp_protocol_version, "2025-06-18"
    ; Otel_genai.Mcp_attr_key.network_protocol_name, "http"
    ; Otel_genai.Mcp_attr_key.network_protocol_version, "2"
    ; Otel_genai.Mcp_attr_key.network_transport, "tcp"
    ; Otel_genai.Mcp_attr_key.error_type, Otel_genai.Mcp_value.tool_error_type
    ]
  in
  let before_count =
    Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
  in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted
      ~clock
      ~sw
      ~profile:Mcp_eio.Managed_agent
      ~mcp_session_id:sid
      ~otel_mcp_protocol_version:"2025-06-18"
      ~otel_transport_context:(Otel_dispatch_hook.http_transport_context ~protocol_version:"2")
      state
      request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "missing params rejected" true
    (String_util.contains_substring response_text "Missing params");
  Alcotest.(check (float 0.0001)) "missing params records duration count"
    1.0
    (Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
     -. before_count);
  cleanup_dir base_path

let test_handle_request_tools_call_managed_invalid_arguments_records_duration () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let sid = "mcp-managed-translation-duration" in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int 115
        ; "method", `String "tools/call"
        ; ( "params"
          , `Assoc
              [ "name", `String "masc_add_task"
              ; "arguments", `String "not-an-object"
              ] )
        ])
  in
  let metric_name = Otel_genai.Mcp_metric_name.server_operation_duration in
  let labels =
    [ Otel_genai.Mcp_attr_key.mcp_method_name, Otel_genai.Mcp_value.tools_call_method
    ; Otel_genai.Attr_key.gen_ai_operation_name, "execute_tool"
    ; Otel_genai.Attr_key.gen_ai_tool_name, "masc_add_task"
    ; Otel_genai.Mcp_attr_key.mcp_protocol_version, "2025-06-18"
    ; Otel_genai.Mcp_attr_key.network_protocol_name, "http"
    ; Otel_genai.Mcp_attr_key.network_protocol_version, "2"
    ; Otel_genai.Mcp_attr_key.network_transport, "tcp"
    ; Otel_genai.Mcp_attr_key.error_type, Otel_genai.Mcp_value.tool_error_type
    ]
  in
  let before_count =
    Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
  in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted
      ~clock
      ~sw
      ~profile:Mcp_eio.Managed_agent
      ~mcp_session_id:sid
      ~otel_mcp_protocol_version:"2025-06-18"
      ~otel_transport_context:(Otel_dispatch_hook.http_transport_context ~protocol_version:"2")
      state
      request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "invalid arguments are rejected at admission" true
    (String_util.contains_substring response_text "arguments must be an object");
  Alcotest.(check (float 0.0001)) "admission error records duration count"
    1.0
    (Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
     -. before_count);
  cleanup_dir base_path

let test_handle_request_tools_call_transition_claim_guidance () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  Auth.disable_auth base_path;
  let sid = "mcp-transition-claim-guidance" in
  let init_result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:Masc_test_deps.no_bearer
      ~mcp_session_id:sid state
      ~name:"masc_init" ~arguments:(`Assoc [])
  in
  (* masc_init and setup join are not under test here; initialise the workspace
     fixture directly so transition guidance assertions are isolated. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false (Tool_result.is_success init_result);
  let _ = Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None in
  let _bound =
    Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"codex" ~capabilities:[] ()
  in
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"transition-claim"
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
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~mcp_session_id:sid state request
  in
  let steps = workflow_next_step_names response in
  Alcotest.(check (option string)) "claim binds current_task" (Some "task-001")
    (Masc.Task.Planning_eio.get_current_task (Mcp_server.workspace_config state));
  Alcotest.(check bool) "claim guidance omits plan_set_task" false
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  Auth.disable_auth base_path;
  let sid = "mcp-deprecated-claim-alias" in
  let init_result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:Masc_test_deps.no_bearer
      ~mcp_session_id:sid state
      ~name:"masc_init" ~arguments:(`Assoc [])
  in
  (* masc_init and setup join are not under test here; initialise the workspace
     fixture directly so transition guidance assertions are isolated. *)
  Alcotest.(check bool) "init returns failure (tool pruned)" false (Tool_result.is_success init_result);
  let _ = Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None in
  let _bound =
    Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"codex" ~capabilities:[] ()
  in
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"deprecated-claim"
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
                ( "arguments",
                  `Assoc
                    [
                      ("task_id", `String "task-001");
                    ] );
              ] );
        ])
  in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~mcp_session_id:sid state request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "missing action rejected" true
    (String_util.contains_substring response_text "action"
     && String_util.contains_substring response_text "MISSING");
  cleanup_dir base_path

let test_handle_request_tools_call_operator_profile_rejects_non_operator () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~profile:Mcp_eio.Operator_remote state request
  in
  (match response with
   | `Assoc fields ->
       (match List.assoc_opt "error" fields with
        | Some (`Assoc error_fields) ->
            Alcotest.(check bool) "method not available" true
              (match List.assoc_opt "message" error_fields with
               | Some (`String msg) ->
                   String_util.contains_substring msg "not available on this MCP endpoint"
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 120);
    ("method", `String "tools/list");
    ("params", `Assoc [
      ("names", `List [ `String "masc_messages"; `String "masc_status" ]);
    ]);
  ]) in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request
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

let test_handle_request_tools_list_include_hidden_metadata () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let tools = tools_list_all ~clock ~sw state in
  let status_tool = find_tool_exn tools "masc_status" in
  Alcotest.(check bool) "standard tools expose title" true
    (tool_string_field status_tool "title" <> "");
  Alcotest.(check bool) "standard tools carry no derived icon" true
    (Yojson.Safe.Util.member "icons" status_tool = `Null);
  Alcotest.(check bool) "standard tools expose annotations" true
    (Yojson.Safe.Util.member "annotations" status_tool <> `Null);
  Alcotest.(check bool) "standard tools do not advertise outputSchema prematurely"
    true
    (Yojson.Safe.Util.member "outputSchema" status_tool = `Null);
  (* Catalog facts are this server's own, so they live under its [_meta] key
     rather than beside the fields [Tool] defines. *)
  let status_catalog =
    status_tool
    |> Yojson.Safe.Util.member "_meta"
    |> Yojson.Safe.Util.member Masc.Mcp_server.tool_catalog_meta_key
  in
  Alcotest.(check bool) "catalog metadata is not a top-level tool field" true
    (Yojson.Safe.Util.member "visibility" status_tool = `Null);
  Alcotest.(check bool) "visibility metadata exposed" true
    (Yojson.Safe.Util.member "visibility" status_catalog <> `Null);
  Alcotest.(check bool) "implementation status exposed" true
    (Yojson.Safe.Util.member "implementationStatus" status_catalog <> `Null);
  Alcotest.(check bool) "removed ghost tool absent" false
    (List.exists
       (function
         | `Assoc fields -> List.assoc_opt "name" fields = Some (`String "masc_post_create")
         | _ -> false)
       tools);

  cleanup_dir base_path

let _test_handle_request_tools_list_hides_internal_tool_by_default () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let tools = tools_list_all ~clock ~sw state in
  Alcotest.(check bool) "internal tool hidden from public surface" false
    (List.exists
       (function
         | `Assoc fields -> (
             match List.assoc_opt "name" fields with
             | Some (`String "tool_search_files") -> true
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 121);
    ("method", `String "tools/list");
    ("params", `Assoc [ ("include_usage", `Bool true) ]);
  ]) in
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  let result_fields = result_fields_exn response in
  let result_usage =
    `Assoc result_fields
    |> Yojson.Safe.Util.member "_meta"
    |> Yojson.Safe.Util.member Masc.Mcp_server.tool_usage_meta_key
  in
  Alcotest.(check bool) "usage counters are not result members" true
    (not (List.mem_assoc "usageTotalCalls" result_fields));
  Alcotest.(check bool) "usage telemetry availability exposed" true
    (Yojson.Safe.Util.member "usageTelemetryAvailable" result_usage <> `Null);
  Alcotest.(check bool) "usage total exposed" true
    (Yojson.Safe.Util.member "usageTotalCalls" result_usage <> `Null);
  let first_tool =
    match tools_from_response response with
    | tool :: _ -> tool
    | [] -> Alcotest.fail "tools list empty"
  in
  let first_tool_usage =
    first_tool
    |> Yojson.Safe.Util.member "_meta"
    |> Yojson.Safe.Util.member Masc.Mcp_server.tool_usage_meta_key
  in
  Alcotest.(check bool) "per-tool usage count exposed" true
    (Yojson.Safe.Util.member "usageCount" first_tool_usage <> `Null);
  (* Present-but-null when the tool was never called, so this asserts the key
     rather than the value. *)
  Alcotest.(check bool) "per-tool last-used field present" true
    (match first_tool_usage with
     | `Assoc fields -> List.mem_assoc "usageLastUsedAt" fields
     | _ -> false);
  cleanup_dir base_path

let test_execute_tool_explicit_agent_name_not_overridden () =
  let base_path = temp_dir () in
  let config = Masc.Workspace.default_config base_path in
  let identity =
    test_agent_identity
      ~uuid:"explicit-agent-identity-test"
      ~session_key:"explicit-agent-session"
  in
  let resolve arguments =
    Masc.Mcp_server_eio_caller_identity.resolve ~config
      ~tool_name:"masc_bind" ~arguments ~identity
      ~cached_resolved_agent:(Some ("cached-stale-nickname", false))
      ~bearer:Masc_test_deps.no_bearer
      ~direct_call_authority:Masc.Mcp_server_eio_caller_identity.Catalog_policy
      ~workspace_initialized:(fun () -> false)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  let codex =
    resolve (`Assoc [ ("agent_name", `String "codex") ])
  in
  Alcotest.(check string)
    "tool-domain agent_name does not override cached caller"
    "cached-stale-nickname" codex.agent_name;
  let gemini =
    resolve (`Assoc [ ("_agent_name", `String "gemini"); ("agent_name", `String "codex") ])
  in
  Alcotest.(check string)
    "internal _agent_name is caller over tool-domain agent_name"
    "gemini" gemini.agent_name;
  let cached = resolve (`Assoc []) in
  Alcotest.(check string)
    "cached session identity wins over generated fallback"
    "cached-stale-nickname"
    cached.agent_name;

  cleanup_dir base_path

let test_execute_tool_domain_agent_name_does_not_reuse_joined_nickname () =
  let base_path = temp_dir () in
  let config = Masc.Workspace.default_config base_path in
  let _ = Masc.Workspace.init config ~agent_name:None in
  let _ = Masc.Workspace.bind_session config ~agent_name:"alpha-agent" ~capabilities:[] () in
  let joined_nickname = Masc.Workspace.resolve_agent_name config "alpha-agent" in
  let identity =
    test_agent_identity
      ~uuid:"explicit-alias-reuse-test"
      ~session_key:"explicit-alias-session"
  in
  let resolved =
    Masc.Mcp_server_eio_caller_identity.resolve ~config
      ~tool_name:"masc_transition"
      ~arguments:(`Assoc [ ("agent_name", `String "alpha-agent") ])
      ~identity ~cached_resolved_agent:None
      ~bearer:Masc_test_deps.no_bearer
      ~direct_call_authority:Masc.Mcp_server_eio_caller_identity.Catalog_policy
      ~workspace_initialized:(fun () -> true)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  Alcotest.(check string)
    "tool-domain agent_name does not resolve caller nickname"
    "agent-explicit" resolved.agent_name;
  Alcotest.(check bool) "joined nickname differs from generated caller" true
    (not (String.equal joined_nickname resolved.agent_name));

  cleanup_dir base_path

let test_execute_tool_generated_agent_name_uses_token_identity () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in

  let status_result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:(Masc_test_deps.door_bearer ~base_path (Some raw_token)) state
      ~name:"masc_auth_status"
      ~arguments:(`Assoc [("agent_name", `String "dashboard-eager-manta")])
  in
  (* masc_auth_status tool pruned from registry; dispatch should fail. *)
  Alcotest.(check bool) "auth status fails (tool pruned)" false (Tool_result.is_success status_result);

  cleanup_dir base_path

let test_execute_tool_actor_mismatch_reports_typed_code () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore
    (Auth.enable_auth
       base_path
       ~require_token:true
       ~agent_name:"bootstrap-admin");
  let raw_token =
    match
      Auth.create_token
        base_path
        ~agent_name:"codex"
        ~role:Masc_domain.Worker
    with
    | Ok (token, _cred) -> token
    | Error err -> Alcotest.fail (Masc_domain.masc_error_to_string err)
  in
  let result =
    Mcp_eio.execute_tool_eio
      ~sw
      ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:(Masc_test_deps.door_bearer ~base_path (Some raw_token))
      state
      ~name:"masc_status"
      ~arguments:(`Assoc [ "_agent_name", `String "dashboard" ])
  in
  Alcotest.(check bool) "actor mismatch rejected" false (Tool_result.is_success result);
  Alcotest.(check string)
    "typed actor mismatch"
    "actor_mismatch"
    Yojson.Safe.Util.(Tool_result.data result |> member "auth_error_code" |> to_string);
  Alcotest.(check string)
    "actor mismatch is pre-effect"
    "proven_pre_effect"
    Yojson.Safe.Util.(Tool_result.data result |> member "effect_disposition" |> to_string);
  cleanup_dir base_path

let test_execute_tool_internal_agent_name_is_caller_identity () =
  let resolve args =
    Masc.Mcp_server_eio_caller_identity.caller_agent_name_from_arguments
      args
  in
  Alcotest.(check (option string))
    "_agent_name is caller over tool-domain agent_name"
    (Some "stable-admin")
    (resolve
       (`Assoc
         [
           ("_agent_name", `String "stable-admin");
           ("agent_name", `String "claude");
         ]));
  Alcotest.(check (option string))
    "agent_name is not caller fallback"
    None
    (resolve (`Assoc [ ("agent_name", `String "claude") ]));
  Alcotest.(check (option string))
    "unknown internal marker does not fall back to agent_name"
    None
    (resolve
       (`Assoc
         [
           ("_agent_name", `String "unknown");
           ("agent_name", `String "claude");
         ]))

let check_task_still_todo config task_id =
  match
    Masc.Workspace.get_tasks_raw config
    |> List.find_opt (fun (task : Masc_domain.task) -> task.id = task_id)
  with
  | Some { Masc_domain.task_status = Masc_domain.Todo; _ } -> ()
  | Some task ->
      Alcotest.failf "expected %s to remain todo, got %s" task_id
        (Masc_domain.task_status_to_string task.task_status)
  | None -> Alcotest.failf "expected task %s to exist" task_id

let check_auth_preflight_result ~tool_name result =
  let msg = Tool_result.message result in
  Alcotest.(check bool)
    (tool_name ^ " rejected before handler")
    false
    (Tool_result.is_success result);
  Alcotest.(check bool) (tool_name ^ " reports auth/credential blocker") true
    (String_util.contains_substring msg "Token required"
     || String_util.contains_substring msg "Unauthorized"
     || String_util.contains_substring msg "No credential");
  Alcotest.(check (option string))
    (tool_name ^ " policy rejection class")
    (Some "policy_rejection")
    (Option.map
       Tool_result.tool_failure_class_to_string
       (Tool_result.failure_class result));
  Alcotest.(check string)
    (tool_name ^ " typed auth code")
    "missing_token"
    Yojson.Safe.Util.(Tool_result.data result |> member "auth_error_code" |> to_string);
  Alcotest.(check string)
    (tool_name ^ " proves no effect")
    "proven_pre_effect"
    Yojson.Safe.Util.(Tool_result.data result |> member "effect_disposition" |> to_string)

let check_rejected_without_mutation ~tool_name ok msg =
  Alcotest.(check bool) (tool_name ^ " rejected before mutation") false ok;
  Alcotest.(check bool) (tool_name ^ " reports rejection detail") true
    (String.trim msg <> "")

let test_execute_tool_explicit_generated_alias_claim_next_not_rewritten_by_token () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"stable-admin" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"explicit-alias-claim-next"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:(Masc_test_deps.door_bearer ~base_path (Some raw_token)) state
      ~name:"keeper_task_claim"
      ~arguments:(`Assoc [ ("agent_name", `String "dashboard-eager-manta") ])
  in
  check_rejected_without_mutation ~tool_name:"keeper_task_claim"
    (Tool_result.is_success result) ((Tool_result.message result));
  check_task_still_todo (Mcp_server.workspace_config state) "task-001";
  cleanup_dir base_path

let test_execute_tool_explicit_generated_alias_transition_not_rewritten_by_token () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"stable-admin" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"explicit-alias-transition"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:(Masc_test_deps.door_bearer ~base_path (Some raw_token)) state
      ~name:"masc_transition"
      ~arguments:
        (`Assoc
          [
            ("agent_name", `String "dashboard-eager-manta");
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
  in
  check_rejected_without_mutation ~tool_name:"masc_transition"
    (Tool_result.is_success result) ((Tool_result.message result));
  check_task_still_todo (Mcp_server.workspace_config state) "task-001";
  cleanup_dir base_path

let test_execute_tool_hyphenated_generated_alias_claim_next_rejected_without_mutation
    () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Auth.create_token base_path ~agent_name:"mu-king" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"hyphenated-generated-alias-claim-next"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~mcp_session_id:"sid-hyphenated-generated-alias"
      ~bearer:(Masc_test_deps.door_bearer ~base_path (Some raw_token)) state
      ~name:"keeper_task_claim"
      ~arguments:(`Assoc [ ("agent_name", `String "mu-king-warm-heron") ])
  in
  Alcotest.(check bool) "claim_next rejected by public MCP path" false
    (Tool_result.is_success result);
  Alcotest.(check bool) "claim_next points to in-process task handler" true
    (String_util.contains_substring
       (Tool_result.message result)
       "keeper in-process task handler");
  check_task_still_todo (Mcp_server.workspace_config state) "task-001";
  Alcotest.(check (option string)) "current task remains unset after rejection" None
    (Masc.Task.Planning_eio.get_current_task (Mcp_server.workspace_config state));
  cleanup_dir base_path

let test_execute_tool_claim_next_requires_auth_before_mutation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"uncredentialed-agent" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"claim-next-auth-preflight"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:Masc_test_deps.no_bearer
      state
      ~name:"keeper_task_claim"
      ~arguments:(`Assoc [ ("agent_name", `String "uncredentialed-agent") ])
  in
  check_auth_preflight_result ~tool_name:"keeper_task_claim" result;
  check_task_still_todo (Mcp_server.workspace_config state) "task-001";
  Alcotest.(check (option string)) "no current task after rejected claim_next" None
    (Masc.Task.Planning_eio.get_current_task (Mcp_server.workspace_config state));
  cleanup_dir base_path

let test_execute_tool_transition_requires_auth_before_mutation () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"uncredentialed-agent" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"transition-auth-preflight"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:Masc_test_deps.no_bearer
      state
      ~name:"masc_transition"
      ~arguments:
        (`Assoc
          [
            ("agent_name", `String "uncredentialed-agent");
            ("task_id", `String "task-001");
            ("action", `String "claim");
          ])
  in
  check_auth_preflight_result ~tool_name:"masc_transition" result;
  check_task_still_todo (Mcp_server.workspace_config state) "task-001";
  Alcotest.(check (option string)) "no current task after rejected transition" None
    (Masc.Task.Planning_eio.get_current_task (Mcp_server.workspace_config state));
  cleanup_dir base_path

let test_execute_tool_add_task_with_admin_token_without_join () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock
      ~workspace_scope:(Mcp_server.workspace_scope state)
      ~bearer:(Masc_test_deps.door_bearer ~base_path (Some raw_token)) state
      ~name:"masc_add_task"
      ~arguments:
        (`Assoc
          [
            ("title", `String "admin add without join");
            ("priority", `Int 2);
            ("description", `String "");
          ])
  in
  Alcotest.(check bool) "add_task succeeds" true (Tool_result.is_success result);
  Alcotest.(check bool) "response mentions added task" true
    (String_util.contains_substring ((Tool_result.message result)) "Added task-001");
  let task =
    match Masc.Workspace.get_tasks_raw (Mcp_server.workspace_config state) with
    | [ task ] -> task
    | tasks ->
        Alcotest.failf "expected exactly one task, found %d" (List.length tasks)
  in
  Alcotest.(check (option string)) "created_by set from token owner"
    (Some "stable-admin") task.created_by;
  Alcotest.(check string) "task remains todo" "todo"
    (Masc_domain.task_status_to_string task.task_status);
  cleanup_dir base_path

(* The token a resolved caller carries, whichever way its bearer arrived. *)
let bearer_token (caller : Masc.Mcp_server_eio_caller_identity.t) =
  match caller.bearer with
  | Masc.Mcp_server_eio_caller_identity.Admitted { token; _ } -> Some token
  | Masc.Mcp_server_eio_caller_identity.Unread { token; _ } -> token

let test_execute_tool_http_auth_token_overrides_stale_argument_token () =
  let base_path = temp_dir () in
  let config = Masc.Workspace.default_config base_path in
  let identity =
    test_agent_identity
      ~uuid:"http-token-priority-test"
      ~session_key:"http-token-priority-session"
  in
  let result =
    Masc.Mcp_server_eio_caller_identity.resolve ~config
      ~tool_name:"masc_status"
      ~arguments:(`Assoc [ ("token", `String "stale-argument-token") ])
      ~identity ~cached_resolved_agent:None
      ~bearer:
        (Masc.Mcp_server_eio_caller_identity.unread (Some "http-auth-token")
           ~internal_keeper_runtime:false)
      ~direct_call_authority:Masc.Mcp_server_eio_caller_identity.Catalog_policy
      ~workspace_initialized:(fun () -> true)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  Alcotest.(check (option string))
    "http auth token wins over stale argument token"
    (Some "http-auth-token")
    (bearer_token result);
  cleanup_dir base_path

let test_execute_tool_argument_token_ignored_without_http_auth () =
  let base_path = temp_dir () in
  let config = Masc.Workspace.default_config base_path in
  let identity =
    test_agent_identity
      ~uuid:"argument-token-ignored-test"
      ~session_key:"argument-token-ignored-session"
  in
  let result =
    Masc.Mcp_server_eio_caller_identity.resolve ~config
      ~tool_name:"masc_status"
      ~arguments:(`Assoc [ ("token", `String "argument-token") ])
      ~identity ~cached_resolved_agent:None
      ~bearer:Masc_test_deps.no_bearer
      ~direct_call_authority:Masc.Mcp_server_eio_caller_identity.Catalog_policy
      ~workspace_initialized:(fun () -> true)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  Alcotest.(check (option string))
    "argument token ignored without HTTP auth"
    None
    (bearer_token result);
  cleanup_dir base_path

let test_execute_tool_without_mcp_session_uses_generated_identity () =
  let base_path = temp_dir () in
  let config = Masc.Workspace.default_config base_path in
  let identity =
    test_agent_identity
      ~uuid:"generated-identity-no-session-test"
      ~session_key:"nosess00"
  in
  let result =
    Masc.Mcp_server_eio_caller_identity.resolve ~config
      ~tool_name:"masc_broadcast"
      ~arguments:(`Assoc [ ("content", `String "generated identity check") ])
      ~identity ~cached_resolved_agent:None
      ~bearer:Masc_test_deps.no_bearer
      ~direct_call_authority:Masc.Mcp_server_eio_caller_identity.Catalog_policy
      ~workspace_initialized:(fun () -> true)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  Alcotest.(check string)
    "generated fallback"
    "agent-nosess00"
    result.agent_name;

  cleanup_dir base_path

let test_handle_request_invalid_json () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in

  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state "not valid json {{{" in

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
  reset_board_test_globals ();
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 117);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "masc_board_post");
      ("arguments", `Assoc [
        ("_agent_name", `String "tester");
        ("content", `String "hello board");
        ("author", `String "tester");
      ]);
    ]);
  ]) in
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  let structured = structured_content_exn response in
  Alcotest.(check string) "canonical board body" "hello board"
    Yojson.Safe.Util.(structured |> member "body" |> to_string);
  Alcotest.(check bool) "legacy content field stays absent" true
    Yojson.Safe.Util.(structured |> member "content" = `Null);
  Alcotest.(check string) "board author" "tester"
    Yojson.Safe.Util.(structured |> member "author" |> to_string);
  reset_board_test_globals ();
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
    ~finally:(fun () ->
      reset_board_test_globals ();
      cleanup_dir base_path)
    (fun () ->
      reset_board_test_globals ();
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
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
        Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~mcp_session_id:"session-log" state
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
  Keeper_registry.For_testing.clear ();
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      cleanup_dir base_path)
    (fun () ->
      let keeper_name = "alpha" in
      let keeper_meta =
        make_keeper_meta keeper_name
      in
      ignore
        (Keeper_registry.For_testing.register ~base_path keeper_name
           keeper_meta);
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
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
                        [ ("_agent_name", `String keeper_name) ] );
                  ] );
            ])
      in
      let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
      ignore (result_fields_exn response);
      match List.assoc_opt "masc_status" (Keeper_registry.tool_usage_of ~base_path keeper_name) with
      | Some entry ->
          Alcotest.(check int) "tool count" 1 entry.count;
          Alcotest.(check int) "tool successes" 1 entry.successes;
          Alcotest.(check int) "tool deferred" 0 entry.deferred;
          Alcotest.(check int) "tool failures" 0 entry.failures;
          Masc.Keeper_registry_tool_usage_persistence.flush ~base_path keeper_name;
          let persisted =
            Yojson.Safe.from_file
              (Filename.concat base_path ".masc/keepers/tool_usage/alpha.json")
          in
          let open Yojson.Safe.Util in
          Alcotest.(check int) "persisted schema version" 2
            (persisted |> member "schema_version" |> to_int);
          Alcotest.(check string) "persisted tool name" "masc_status"
            (persisted |> member "tools" |> index 0 |> member "tool" |> to_string);
          Alcotest.(check int) "persisted deferred count" 0
            (persisted |> member "tools" |> index 0 |> member "deferred" |> to_int);
          Keeper_registry.For_testing.unregister ~base_path keeper_name;
          ignore (Keeper_registry.For_testing.register ~base_path keeper_name keeper_meta);
          let registered =
            Keeper_registry.get ~base_path keeper_name
            |> Option.get
          in
          let launch_token =
            match
              Keeper_lifecycle_reservation.acquire
                ~base_path
                ~keeper_name
                ~purpose:Keepalive_launch
            with
            | Ok token -> token
            | Error _ -> Alcotest.fail "failed to reserve keeper launch lifecycle"
          in
          Fun.protect
            ~finally:(fun () ->
              ignore (Keeper_lifecycle_reservation.release launch_token))
            (fun () ->
              (* The ordinary replay is fenced while launch owns the key. The
                 launch path must carry its exact mutation authority instead of
                 silently dropping the persisted counters. *)
              Masc.Keeper_registry_tool_usage_persistence.restore
                ~base_path
                keeper_name;
              Alcotest.(check (list string))
                "unqualified restore is fenced"
                []
                (Keeper_registry.tool_usage_of ~base_path keeper_name
                 |> List.map fst);
              Masc.Keeper_registry_tool_usage_persistence.restore_for_lifecycle
                launch_token
                registered);
          let restored =
            List.assoc_opt
              "masc_status"
              (Keeper_registry.tool_usage_of ~base_path keeper_name)
          in
          Alcotest.(check (option int))
            "current schema restores exact count"
            (Some 1)
            (Option.map (fun restored -> restored.Keeper_types.count) restored);
          let persisted_path =
            Filename.concat base_path ".masc/keepers/tool_usage/alpha.json"
          in
          Fs_compat.save_file
            persisted_path
            (Yojson.Safe.to_string
               (`Assoc
                 [ "keeper", `String keeper_name
                 ; "tools", `List []
                 ])
             ^ "\n");
          Keeper_registry.For_testing.unregister ~base_path keeper_name;
          ignore (Keeper_registry.For_testing.register ~base_path keeper_name keeper_meta);
          Masc.Keeper_registry_tool_usage_persistence.restore ~base_path keeper_name;
          Alcotest.(check (list string))
            "legacy schema is rejected without migration"
            []
            (Keeper_registry.tool_usage_of ~base_path keeper_name
             |> List.map fst)
      | None -> Alcotest.fail "expected keeper tool usage for masc_status")

let test_handle_request_tools_call_blocks_keeper_internal_tool () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 118);
    ("method", `String "tools/call");
    ("params", `Assoc [
      ("name", `String "keeper_lane_status");
      ("arguments", `Assoc []);
    ]);
  ]) in
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  let result = result_fields_exn response in
  Alcotest.(check bool) "unknown keeper internal tool isError" true
    (match List.assoc_opt "isError" result with
     | Some (`Bool value) -> value
     | _ -> Alcotest.fail "missing isError");
  let msg =
    match List.assoc_opt "content" result with
    | Some (`List (`Assoc fields :: _)) -> (
        match List.assoc_opt "text" fields with
        | Some (`String text) -> text
        | _ -> Alcotest.fail "missing content text")
    | _ -> Alcotest.fail "missing content"
  in
  (* keeper_lane_status is registered but keeper-internal: the endpoint blocks
     it with the typed refusal, not the "Unknown tool" misreport. *)
  Alcotest.(check bool) "names keeper_lane_status" true
    (String_util.contains_substring msg "keeper_lane_status");
  Alcotest.(check bool) "mentions keeper-internal refusal" true
    (String_util.contains_substring msg "keeper-internal");
  Alcotest.(check bool) "mentions endpoint unavailability" true
    (String_util.contains_substring msg "not available on this MCP endpoint");
  cleanup_dir base_path

let tool_names_from_list_response response =
  match response with
  | `Assoc fields -> (
      match List.assoc_opt "result" fields with
      | Some (`Assoc result_fields) -> (
          match List.assoc_opt "tools" result_fields with
          | Some (`List tools) ->
              tools
              |> List.filter_map (function
                   | `Assoc fields -> List.assoc_opt "name" fields
                   | _ -> None)
              |> List.filter_map (function `String s -> Some s | _ -> None)
          | _ -> Alcotest.fail "tools not a list")
      | _ -> Alcotest.fail "result not an object")
  | _ -> Alcotest.fail "response not an object"

let test_internal_keeper_lane_access_requires_verified_runtime_and_keeper () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.clear (); cleanup_dir base_path)
    (fun () ->
      Keeper_registry.For_testing.clear ();
      let config = Masc.Workspace.default_config base_path in
      let meta_path = Masc.Keeper_types_profile.keeper_meta_path config "alpha" in
      Fs_compat.mkdir_p (Filename.dirname meta_path);
      Yojson.Safe.to_file meta_path (Masc.Keeper_meta_json.meta_to_json (make_keeper_meta "alpha"));
      let token = Auth.ensure_internal_keeper_token base_path in
      let resolve ~internal_keeper_runtime ~token ~name =
        let caller = Masc.Mcp_server_eio_caller_identity.resolve ~config
          ~tool_name:"masc_lane_inspect" ~arguments:(`Assoc ["_agent_name", `String name])
          ~identity:(test_agent_identity ~uuid:"lane-runtime" ~session_key:"lane-runtime")
          ~cached_resolved_agent:None
          ~bearer:(Masc.Mcp_server_eio_caller_identity.unread (Some token) ~internal_keeper_runtime)
          ~direct_call_authority:Masc.Mcp_server_eio_caller_identity.Catalog_policy
          ~workspace_initialized:(fun () -> false) ~log_mcp_exn:(fun ~label:_ _ -> ()) in
        caller in
      let access ~internal_keeper_runtime ~token ~name =
        Masc.Mcp_server_eio_execute.lane_access_for_caller ~config
          (resolve ~internal_keeper_runtime ~token ~name) in
      let caller=resolve ~internal_keeper_runtime:true ~token ~name:"alpha" in
      Alcotest.(check bool) "browser actor is the verified canonical Keeper" true
        (Masc.Mcp_server_eio_execute.browser_principal_for_caller ~config caller=
          Lane_addon_call_context.Keeper "alpha");
      let spoofed={caller with bearer=Masc_test_deps.no_bearer;verified_internal_keeper_runtime=false} in
      Alcotest.(check bool) "a resolved caller name without credential is not browser authority" true
        (Masc.Mcp_server_eio_execute.browser_principal_for_caller ~config spoofed=
          Lane_addon_call_context.Anonymous);
      Alcotest.(check bool) "verified runtime resolves existing Keeper" true
        (access ~internal_keeper_runtime:true ~token ~name:"alpha" = Masc.Lane_addon_sources.Keeper "alpha");
      List.iter (fun (internal_keeper_runtime, token, name) ->
        Alcotest.(check bool) "unverified or missing Keeper stays unauthenticated" true
          (access ~internal_keeper_runtime ~token ~name = Masc.Lane_addon_sources.Unauthenticated))
        [false, token, "alpha"; true, "invalid-token", "alpha"; true, token, "missing"])

(* RFC a-request-reads-its-bearer-once-at-the-door, D5: a bearer the door
   resolved answers the executor's identity and lookups the way its token
   did. Each case resolves the same call twice, once with the door's answer
   and once reading the token, and compares what the executor would use. *)
let test_door_bearer_answers_caller_identity_as_the_token_did () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let config = Masc.Workspace.default_config base_path in
    ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
    let resolve ~bearer arguments =
      Masc.Mcp_server_eio_caller_identity.resolve ~config ~tool_name:"masc_status"
        ~arguments
        ~identity:(test_agent_identity ~uuid:"door-bearer" ~session_key:"door-bearer")
        ~cached_resolved_agent:None ~bearer
        ~direct_call_authority:Masc.Mcp_server_eio_caller_identity.Catalog_policy
        ~workspace_initialized:(fun () -> false)
        ~log_mcp_exn:(fun ~label:_ _ -> ())
    in
    List.iter
      (fun (role, owner) ->
        let raw =
          match Auth.create_token base_path ~agent_name:owner ~role with
          | Ok (token, _) -> token
          | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
        in
        let admitted = Masc_test_deps.door_bearer ~base_path (Some raw) in
        (* Both authorization branches of D5 rest on this: the door's role is
           the one [Auth.resolve_role] gives the owner and the token. *)
        Alcotest.(check bool) (owner ^ ": the door's role is the token's role") true
          (match admitted with
           | Masc.Mcp_server_eio_caller_identity.Admitted { role; _ } ->
             Auth.resolve_role base_path ~agent_name:owner ~token:(Some raw) = Ok role
           | Masc.Mcp_server_eio_caller_identity.Unread _ -> false);
        let unread =
          Masc.Mcp_server_eio_caller_identity.unread (Some raw)
            ~internal_keeper_runtime:false
        in
        List.iter
          (fun (case, arguments) ->
            let label what = Printf.sprintf "%s, %s: %s" owner case what in
            let door = resolve ~bearer:admitted arguments in
            let token = resolve ~bearer:unread arguments in
            Alcotest.(check string) (label "caller name") token.agent_name door.agent_name;
            Alcotest.(check bool) (label "ephemerality")
              token.agent_name_is_ephemeral door.agent_name_is_ephemeral;
            Alcotest.(check bool) (label "internal Keeper runtime")
              token.verified_internal_keeper_runtime door.verified_internal_keeper_runtime;
            Alcotest.(check (option (pair string (option string))))
              (label "Keeper owner") token.owner_keeper_identity door.owner_keeper_identity;
            Alcotest.(check bool) (label "Lane access") true
              (Masc.Mcp_server_eio_execute.lane_access_for_caller ~config door
               = Masc.Mcp_server_eio_execute.lane_access_for_caller ~config token);
            Alcotest.(check bool) (label "browser principal") true
              (Masc.Mcp_server_eio_execute.browser_principal_for_caller ~config door
               = Masc.Mcp_server_eio_execute.browser_principal_for_caller ~config token))
          [ "generated name", `Assoc []
          ; "the owner's name", `Assoc [ "_agent_name", `String owner ]
          ; "another name", `Assoc [ "_agent_name", `String "someone-else" ]
          ])
      [ Masc_domain.Admin, "door-admin"
      ; Masc_domain.Worker, "door-worker"
      ; Masc_domain.Player, "door-player"
      ];
    (* The internal Keeper token passes the door with its Keeper header, and
       dispatch still looks it up (D3), so the executor reads it as before. *)
    let internal = Auth.ensure_internal_keeper_token base_path in
    match
      Auth.admit_request base_path ~auth_cfg:(Auth.load_auth_config base_path)
        ~token:(Some internal) ~internal_keeper_agent:(Some "door-keeper")
    with
    | Error _ -> Alcotest.fail "the door refused the internal Keeper token"
    | Ok principal ->
      Alcotest.(check bool) "the internal Keeper token stays unread" true
        (match
           Masc.Mcp_server_eio_caller_identity.of_sender
             (Masc.Mcp_server_eio.Admitted principal)
             ~auth_token:(Some internal) ~internal_keeper_runtime:true
         with
         | Masc.Mcp_server_eio_caller_identity.Unread
             { token = Some token; internal_keeper_runtime = true } ->
           String.equal token internal
         | Masc.Mcp_server_eio_caller_identity.Unread _
         | Masc.Mcp_server_eio_caller_identity.Admitted _ -> false))

(* D5: a call that names the credential's owner is authorized by the role the
   door gave, without reading the token again. The credential is deleted
   after the door admitted the bearer, so a read would refuse. A call under
   another name still pairs that name with the token, and a token no door
   read is read as before; both meet the deleted credential. *)
let test_executor_authorizes_the_owner_from_the_door_answer () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) (fun () ->
    let state = Mcp_eio.For_testing.create_state ~base_path () in
    ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
    let raw =
      match Auth.create_token base_path ~agent_name:"door-worker" ~role:Masc_domain.Worker with
      | Ok (token, _) -> token
      | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
    in
    let admitted = Masc_test_deps.door_bearer ~base_path (Some raw) in
    Auth.delete_credential base_path "door-worker";
    let call ~bearer caller =
      Mcp_eio.execute_tool_eio ~sw ~clock
        ~workspace_scope:(Mcp_server.workspace_scope state)
        ~bearer state ~name:"masc_tool_help"
        ~arguments:
          (`Assoc [ "_agent_name", `String caller; "tool_name", `String "masc_status" ])
    in
    let owner = call ~bearer:admitted "door-worker" in
    Alcotest.(check bool)
      ("the owner's call takes the door's role: " ^ Tool_result.message owner)
      true (Tool_result.is_success owner);
    Alcotest.(check bool) "another name pairs with the deleted credential's token" false
      (Tool_result.is_success (call ~bearer:admitted "someone-else"));
    Alcotest.(check bool) "a token no door read meets the deleted credential" false
      (Tool_result.is_success
         (call
            ~bearer:
              (Masc.Mcp_server_eio_caller_identity.unread (Some raw)
                 ~internal_keeper_runtime:false)
            "door-worker")))

let test_handle_request_tools_list_internal_keeper_runtime_hides_keeper_internal_tools
    () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let token = Auth.ensure_internal_keeper_token base_path in
      let request = Yojson.Safe.to_string (`Assoc [
        ("jsonrpc", `String "2.0");
        ("id", `Int 119);
        ("method", `String "tools/list");
        ("params", `Assoc []);
      ]) in
      let response =
        Mcp_eio.handle_request ~clock ~sw
          ~sender:(Masc_test_deps.door_sender ~base_path (Some token))
          ~auth_token:token ~internal_keeper_runtime:true state request
      in
      let names = tool_names_from_list_response response in
      Alcotest.(check bool) "tool_execute is not externally discovered" false
        (List.mem "tool_execute" names))

let test_handle_request_tools_call_internal_keeper_runtime_rejects_unknown_execute
    () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.clear ();
      cleanup_dir base_path)
    (fun () ->
      Keeper_registry.For_testing.clear ();
      let keeper_name = "alpha" in
      ignore
        (Keeper_registry.For_testing.register ~base_path keeper_name
           (make_keeper_meta keeper_name));
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let token = Auth.ensure_internal_keeper_token base_path in
      let request = Yojson.Safe.to_string (`Assoc [
        ("jsonrpc", `String "2.0");
        ("id", `Int 120);
        ("method", `String "tools/call");
        ("params", `Assoc [
          ("name", `String "tool_execute");
          ( "arguments",
            `Assoc
              [
                ("_agent_name", `String keeper_name);
                ("argv", `List [ `String "pwd" ]);
              ] );
        ]);
      ]) in
      let response =
        Mcp_eio.handle_request ~clock ~sw
          ~sender:(Masc_test_deps.door_sender ~base_path (Some token))
          ~auth_token:token ~internal_keeper_runtime:true state request
      in
      let result = result_fields_exn response in
      Alcotest.(check bool) "tool_execute is an MCP tool-result error" true
        (match List.assoc_opt "isError" result with
         | Some (`Bool value) -> value
         | _ -> Alcotest.fail "missing isError");
      let msg =
        match List.assoc_opt "content" result with
        | Some (`List (`Assoc fields :: _)) -> (
            match List.assoc_opt "text" fields with
            | Some (`String text) -> text
            | _ -> Alcotest.fail "missing content text")
        | _ -> Alcotest.fail "missing content"
      in
      (* tool_execute is registered (tag registry) but has no executor on the
         MCP endpoint: the rejection is the typed keeper-internal refusal,
         not the "Unknown tool (registry inconsistency)" misreport. *)
      Alcotest.(check bool) "names tool_execute" true
        (String_util.contains_substring msg "tool_execute");
      Alcotest.(check bool) "mentions keeper-internal refusal" true
        (String_util.contains_substring msg "keeper-internal");
      Alcotest.(check bool) "mentions endpoint unavailability" true
        (String_util.contains_substring msg "not available on this MCP endpoint"))

let test_handle_request_batch_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  Alcotest.(check int) "batch rejected" (-32600) (error_code_exn response);
  Alcotest.(check bool) "mentions batch unsupported" true
    (String_util.contains_substring (error_message_exn response) "batch requests are not supported");
  cleanup_dir base_path

let test_handle_request_jsonrpc_response_returns_null () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 1);
          ("result", `String "already a response");
        ])
  in
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  Alcotest.(check bool) "response ignored" true (response = `Null);
  cleanup_dir base_path

let test_handle_request_method_not_found () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->

  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in

  let request = Yojson.Safe.to_string (`Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 99);
    ("method", `String "unknown/method");
    ("params", `Assoc []);
  ]) in

  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in

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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check bool) "unsupported tier error" true
    (String_util.contains_substring (error_message_exn response) "unsupported field(s): tier");
  cleanup_dir base_path

let test_handle_request_resources_list_rejects_unknown_field () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  Alcotest.(check bool) "unknown field rejected" true
    (String_util.contains_substring (error_message_exn response) "unsupported field");
  cleanup_dir base_path

let test_handle_request_resources_templates_rejects_invalid_cursor () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  let msg = error_message_exn response in
  Alcotest.(check bool)
    "invalid cursor error preserves contract label" true
    (String_util.contains_substring msg "Invalid params: cursor");
  Alcotest.(check bool)
    "invalid cursor error names received string" true
    (String_util.contains_substring msg "not-base64");
  cleanup_dir base_path

let test_handle_request_prompts_list_rejects_invalid_cursor () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  Alcotest.(check int) "invalid params code" (-32602) (error_code_exn response);
  let msg = error_message_exn response in
  Alcotest.(check bool)
    "invalid cursor error preserves contract label" true
    (String_util.contains_substring msg "Invalid params: cursor");
  Alcotest.(check bool)
    "invalid cursor error names received string" true
    (String_util.contains_substring msg "bad-cursor");
  cleanup_dir base_path

let test_handle_request_prompts_list_non_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
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
    (List.length prompts >= 1);
  cleanup_dir base_path

let test_handle_request_prompts_list_cursor () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
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
  Alcotest.(check int) "cursor trims first prompt" 0 (List.length prompts);
  cleanup_dir base_path

let test_handle_request_prompts_get_tool_help () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
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
    (String_util.contains_substring description "tool");
  Alcotest.(check bool) "prompt has one or more messages" true
    (messages <> []);
  cleanup_dir base_path

let test_handle_request_resources_list_includes_tool_help () =
  with_env "MASC_LIST_PAGE_SIZE" "10" @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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

(* The wiki pages are otherwise reachable only through the
   [masc://wiki/{topic}] template. A client that lists resources, the TUI
   Resources screen among them, has to find each page in the listing. *)
let test_handle_request_resources_list_includes_wiki_pages () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let wiki_dir = Masc.Tool_wiki.wiki_root ~base_path in
  let ensure_dir dir = if not (Sys.file_exists dir) then Unix.mkdir dir 0o755 in
  ensure_dir (Filename.dirname wiki_dir);
  ensure_dir wiki_dir;
  let oc = open_out (Filename.concat wiki_dir "alpha.md") in
  output_string oc
    "---\ntitle: Alpha Doc\nsummary: What alpha holds\nsource: research\nauthor: codex\n\
     created: 2026-09-22\nrevision: 1\ntags: []\n---\nAlpha body\n";
  close_out oc;
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let resources = resources_list_all ~clock ~sw state [] in
  let field name = function
    | `Assoc fields -> List.assoc_opt name fields
    | _ -> None
  in
  (match
     List.find_opt
       (fun resource -> field "uri" resource = Some (`String "masc://wiki/alpha"))
       resources
   with
   | None -> Alcotest.fail "the page was not in the resources/list answer"
   | Some resource ->
     Alcotest.(check bool) "title is the page title" true
       (field "title" resource = Some (`String "Alpha Doc"));
     Alcotest.(check bool) "description is the page summary" true
       (field "description" resource = Some (`String "What alpha holds")));
  cleanup_dir base_path

let test_handle_request_resources_list_paginates () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
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

(* The catalogue the server lists (config/mcp/resources.toml, surfaced as
   [Mcp_server.resources] / [resource_templates]) and the reader dispatch in
   mcp_server_eio_resource.ml must agree. Pin the join through the same closed
   target type the reader uses: every listed uri, and every uri_template with
   concrete values substituted, must parse to a handled target. *)
let handled_resource_id id =
  match Masc.Mcp_server_eio_resource.parse_resource_target id with
  | Tool_help_index | Tool_help _
  | Status_markdown | Status_json | Tasks_markdown | Tasks_json
  | Who_markdown | Who_json | Messages_markdown | Messages_json
  | Events_markdown | Events_json
  | Wiki_index_markdown | Wiki_index_json | Wiki_page_markdown _ | Wiki_page_json _
  | World_memory_claims | World_memory_digest | World_memory_index | World_memory_fact _ | World_memory_log
  | Keeper_memory _ | Keeper_memory_health _ ->
      true
  | Unknown _ -> false

let concrete_uri_of_template uri_template =
  (* RFC 6570: a query expression ({?...}) drops out; a path variable
     ({topic}) becomes one concrete segment. *)
  let len = String.length uri_template in
  let buf = Buffer.create len in
  let rec walk i =
    if i < len then
      match uri_template.[i] with
      | '{' ->
          let close = String.index_from uri_template i '}' in
          if i + 1 < len && uri_template.[i + 1] = '?' then
            ()
          else
            Buffer.add_char buf 'x';
          walk (close + 1)
      | c ->
          Buffer.add_char buf c;
          walk (i + 1)
  in
  walk 0;
  Buffer.contents buf

let test_listed_resource_uris_have_readers () =
  let check_uri uri =
    let id, _uri = Mcp.parse_masc_resource_uri uri in
    Alcotest.(check bool)
      (Printf.sprintf "%s reads as handled id %S" uri id)
      true
      (handled_resource_id id)
  in
  List.iter (fun (r : Mcp.mcp_resource) -> check_uri r.uri) Mcp.resources;
  List.iter
    (fun (t : Mcp.mcp_resource_template) ->
      check_uri (concrete_uri_of_template t.uri_template))
    Mcp.resource_templates

let test_handle_request_tools_list_paginates () =
  with_env "MASC_LIST_PAGE_SIZE" "10" @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let second_page = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
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
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
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
    (String_util.contains_substring text "# masc_status");
  cleanup_dir base_path

let test_handle_request_resources_read_matrix () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:(Some "fixture-root"));
  let ensure_dir path =
    if not (Sys.file_exists path) then Unix.mkdir path 0o755
  in
  let wiki_dir = Masc.Tool_wiki.wiki_root ~base_path in
  let masc_dir = Filename.concat base_path Common.masc_dirname in
  ensure_dir masc_dir;
  ensure_dir wiki_dir;
  write_text_file (Filename.concat wiki_dir "alpha.md")
    {|---
title: Alpha Doc
summary: What alpha holds
source: research
author: codex
created: 2026-03-12
updated: 2026-03-12
revision: 1
tags: [alpha, keeper]
---
Alpha body
|};
  let cases =
    [
      ("masc://status.json", "application/json", "\"base_path\"");
      ("masc://tasks.json", "application/json", "\"tasks\"");
      ("masc://who.json", "application/json", "[");
      ("masc://messages.json", "application/json", "[");
      ("masc://events.json", "application/json", "[");
      ("masc://wiki", "text/markdown", "`masc://wiki/alpha` (research)");
      ("masc://wiki.json", "application/json", "\"source\":\"research\"");
      ("masc://wiki/alpha", "text/markdown", "Alpha body");
      ("masc://wiki/alpha.json", "application/json", "\"Alpha body\"");
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
      let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
      Alcotest.(check string) (uri ^ " mime type") expected_mime
        (resource_mime_type_exn response);
      Alcotest.(check bool) (uri ^ " text contains expected") true
        (String_util.contains_substring (resource_text_exn response) expected_text))
    cases;
  cleanup_dir base_path

let test_handle_request_keeper_memory_access_and_readership () =
  let module Memory_types = Masc.Keeper_memory_os_types in
  let module Memory_current = Masc.Keeper_memory_os_current in
  let module Resource = Masc.Mcp_server_eio_resource in
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  reset_board_test_globals ();
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      reset_board_test_globals ();
      if not was_ready then Eio_guard.disable ();
      cleanup_dir base_path)
    (fun () ->
      let state = Mcp_eio.For_testing.create_state ~base_path () in
      let config = Mcp_server.workspace_config state in
      let every_name_declared =
        Masc_board_handlers.Recipient_lookup.make (fun candidate ->
          Ok
            (Result.to_option
               (Masc.Board.Agent_id.parse
                  (Masc_board_handlers.Recipient_lookup.Candidate.to_string candidate))))
      in
      (match
         Masc.Board_dispatch.init_jsonl ~base_path ~recipient_lookup:every_name_declared ()
       with
       | Ok () -> ()
       | Error _ -> Alcotest.fail "Board_dispatch.init_jsonl failed");
      let pub_post =
        match
          Masc.Board_dispatch.create_post ~author:"beta" ~content:"Public milestone"
            ~post_kind:Masc.Board.Human_post ~visibility:Masc.Board.Public ()
        with
        | Ok p -> p
        | Error e -> Alcotest.fail (Masc.Board.Post_publication_failure.to_string e)
      in
      let priv_post =
        match
          Masc.Board_dispatch.create_post ~author:"beta" ~content:"Secret plan for @beta"
            ~post_kind:Masc.Board.Human_post ~visibility:Masc.Board.Direct ()
        with
        | Ok p -> p
        | Error e -> Alcotest.fail (Masc.Board.Post_publication_failure.to_string e)
      in
      let pub_ref =
        match
          Memory_types.board_ref_of_ids
            ~post_id:(Masc.Board.Post_id.to_string pub_post.id)
            ~comment_id:None
        with
        | Ok r -> r
        | Error err -> Alcotest.fail (Memory_types.wire_error_to_string err)
      in
      let priv_ref =
        match
          Memory_types.board_ref_of_ids
            ~post_id:(Masc.Board.Post_id.to_string priv_post.id)
            ~comment_id:None
        with
        | Ok r -> r
        | Error err -> Alcotest.fail (Memory_types.wire_error_to_string err)
      in
      Masc_test_deps.declare_fixture_keeper
        ~sandbox_image:"base"
        ~base_path
        ~sandbox_profile:(Some Masc.Keeper_types_profile.Docker)
        "alpha";
      (match Masc.Keeper_meta_store.replace_snapshot config (make_keeper_meta "alpha") with
       | Ok () -> ()
       | Error err -> Alcotest.fail ("replace_snapshot failed: " ^ err));
      let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
      let now = 1_700_000_000.0 in
      let origin = { Memory_types.kind = Memory_types.Injected; trace_id = "trace-alpha" } in
      let transcript_fact =
        Memory_types.observed ~claim:"Alpha uses OCaml 5" ~category:Memory_types.Fact ~now ~origin
      in
      let public_board_fact =
        { (Memory_types.observed ~claim:"Beta posted public milestone" ~category:Memory_types.Fact
             ~now ~origin)
          with
          basis = Memory_types.Observed (Memory_types.Board pub_ref)
        }
      in
      let direct_board_fact =
        { (Memory_types.observed ~claim:"Beta secret plan" ~category:Memory_types.Fact ~now
             ~origin)
          with
          basis = Memory_types.Observed (Memory_types.Board priv_ref)
        }
      in
      let derived_on_direct =
        match
          Memory_types.derived ~claim:"Derived from Beta secret" ~category:Memory_types.Lesson
            ~now ~origin
            ~derivations:
              [ { Memory_types.rule_id = "rule-secret"
                ; premise_ids = [ Memory_types.memory_id direct_board_fact ]
                }
              ]
        with
        | Ok f -> f
        | Error err -> Alcotest.fail err
      in
      let derived_on_transcript =
        match
          Memory_types.derived ~claim:"Derived from OCaml transcript" ~category:Memory_types.Lesson
            ~now ~origin
            ~derivations:
              [ { Memory_types.rule_id = "rule-transcript"
                ; premise_ids = [ Memory_types.memory_id transcript_fact ]
                }
              ]
        with
        | Ok f -> f
        | Error err -> Alcotest.fail err
      in
      let facts =
        [ transcript_fact
        ; public_board_fact
        ; direct_board_fact
        ; derived_on_direct
        ; derived_on_transcript
        ]
      in
      let snap : Memory_current.t =
        { revision = 1
        ; updated_at = now
        ; source = { kind = Memory_current.Librarian; trace_id = "trace-alpha" }
        ; facts
        ; change = { added = facts; removed = []; retained = 0; invalidated = [] }
        }
      in
      Fs_compat.mkdir_p keepers_dir;
      (match
         Fs_compat.save_file_atomic_strict
           (Memory_current.path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha")
           (Yojson.Safe.pretty_to_string (Memory_current.to_json snap) ^ "\n")
       with
       | Ok () -> ()
       | Error err -> Alcotest.fail ("snapshot write failed: " ^ err));
      (* 1. Default omitted caller on handle_read_resource_eio fails closed (-32001). *)
      let read_direct ?caller id_num uri =
        Resource.handle_read_resource_eio ?caller state (`Int id_num)
          (Some (`Assoc [ ("uri", `String uri) ]))
      in
      Alcotest.(check int) "default caller refused on keeper/memory" (-32001)
        (error_code_exn (read_direct 1 "masc://keepers/alpha/memory"));
      Alcotest.(check int) "default caller refused on keeper/memory/health" (-32001)
        (error_code_exn (read_direct 2 "masc://keepers/alpha/memory/health"));
      (* 2. Auth-off Unadmitted request resolves to Operator_admin, which reads
            board deliveries as the target keeper (N2-B1 / #54377) rather than
            bypassing Direct post visibility, withholding beta's 2 Direct-derived facts. *)
      let read_via_protocol ~sender ?auth_token uri =
        let req =
          Yojson.Safe.to_string
            (`Assoc
              [ ("jsonrpc", `String "2.0")
              ; ("id", `Int 10)
              ; ("method", `String "resources/read")
              ; ("params", `Assoc [ ("uri", `String uri) ])
              ])
        in
        Mcp_eio.handle_request ~sender ?auth_token ~clock ~sw state req
      in
      let auth_off_json =
        Yojson.Safe.from_string
          (resource_text_exn
             (read_via_protocol ~sender:Mcp_eio.Unadmitted "masc://keepers/alpha/memory"))
      in
      Alcotest.(check int) "auth-off withholds beta direct + derived facts (2)" 2
        Yojson.Safe.Util.(auth_off_json |> member "withheld_fact_count" |> to_int);
      Alcotest.(check int) "auth-off sees 3 readable facts" 3
        Yojson.Safe.Util.
          (auth_off_json |> member "ordinary" |> member "facts" |> to_list |> List.length);
      (* 3. Enable auth and test Admin, other Worker, and matching Keeper. *)
      ignore (Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
      let mk_token agent_name role =
        match Auth.create_token base_path ~agent_name ~role with
        | Ok (tok, _) -> tok
        | Error err -> Alcotest.fail (Masc_domain.masc_error_to_string err)
      in
      let admit raw =
        let auth_cfg = Auth.load_auth_config base_path in
        match
          Auth.admit_request base_path ~auth_cfg ~token:(Some raw) ~internal_keeper_agent:None
        with
        | Ok principal -> Mcp_eio.Admitted principal
        | Error _ -> Alcotest.fail "Auth.admit_request failed"
      in
      let admin_tok = mk_token "op-admin" Masc_domain.Admin in
      let alpha_tok = mk_token "alpha" Masc_domain.Worker in
      let beta_tok = mk_token "beta" Masc_domain.Worker in
      let admin_json =
        Yojson.Safe.from_string
          (resource_text_exn
             (read_via_protocol ~sender:(admit admin_tok) ~auth_token:admin_tok
                "masc://keepers/alpha/memory"))
      in
      Alcotest.(check int) "admin withholds beta direct + derived facts (2)" 2
        Yojson.Safe.Util.(admin_json |> member "withheld_fact_count" |> to_int);
      Alcotest.(check int) "admin sees 3 readable facts" 3
        Yojson.Safe.Util.(admin_json |> member "ordinary" |> member "facts" |> to_list |> List.length);
      let beta_resp =
        read_via_protocol ~sender:(admit beta_tok) ~auth_token:beta_tok
          "masc://keepers/alpha/memory"
      in
      Alcotest.(check int) "non-matching worker gets Insufficient_scope (-32007)" (-32007)
        (error_code_exn beta_resp);
      let anon_resp =
        read_via_protocol ~sender:Mcp_eio.Unadmitted "masc://keepers/alpha/memory"
      in
      Alcotest.(check int) "unadmitted gets Auth_error (-32001)" (-32001)
        (error_code_exn anon_resp);
      let alpha_json =
        Yojson.Safe.from_string
          (resource_text_exn
             (read_via_protocol ~sender:(admit alpha_tok) ~auth_token:alpha_tok
                "masc://keepers/alpha/memory"))
      in
      Alcotest.(check int) "matching keeper withholds direct + derived (2)" 2
        Yojson.Safe.Util.(alpha_json |> member "withheld_fact_count" |> to_int);
      let alpha_facts =
        Yojson.Safe.Util.(alpha_json |> member "ordinary" |> member "facts" |> to_list)
      in
      Alcotest.(check int) "matching keeper keeps 3 readable facts" 3 (List.length alpha_facts);
      let alpha_claims =
        List.map (fun f -> Yojson.Safe.Util.(f |> member "claim" |> to_string)) alpha_facts
      in
      Alcotest.(check bool) "withheld direct claim absent" false
        (List.mem "Beta secret plan" alpha_claims);
      Alcotest.(check bool) "withheld derived claim absent" false
        (List.mem "Derived from Beta secret" alpha_claims);
      Alcotest.(check bool) "readable derived claim kept" true
        (List.mem "Derived from OCaml transcript" alpha_claims);
      let change_json = Yojson.Safe.Util.(alpha_json |> member "ordinary" |> member "change") in
      let added_len = Yojson.Safe.Util.(change_json |> member "added" |> to_list |> List.length) in
      let retained_n = Yojson.Safe.Util.(change_json |> member "retained" |> to_int) in
      Alcotest.(check int) "change.added scrubbed to 3 readable facts" 3 added_len;
      Alcotest.(check int) "change retained + added = facts" 3 (retained_n + added_len);
      (* 4. For_testing delta scrub: removed/invalidated withhold unreadable Board and ungrounded Derived. *)
      let dirty_snap : Memory_current.t =
        { snap with
          change =
            { snap.change with
              removed = [ direct_board_fact; derived_on_direct; transcript_fact ]
            ; invalidated =
                [ { fact = direct_board_fact; missing_premise_ids = [] }
                ; { fact = derived_on_direct
                  ; missing_premise_ids = [ Memory_types.memory_id direct_board_fact ]
                  }
                ]
            }
        }
      in
      let filtered_dirty, dirty_withheld =
        Resource.For_testing.filter_ordinary_snapshot_for_reader ~base_path
          ~reader:(Masc_board_handlers.Board_access.named "alpha") dirty_snap
      in
      Alcotest.(check int) "dirty snap withheld 2 facts" 2 dirty_withheld;
      Alcotest.(check int) "removed keeps only readable transcript fact" 1
        (List.length filtered_dirty.change.removed);
      Alcotest.(check int) "invalidated drops withheld direct and derived" 0
        (List.length filtered_dirty.change.invalidated);
      (* 5. Memory health denies cross-keeper workers (-32007), allows matching keeper and admin,
            and returns closed G16 tokens/counts without free-text detail/rejection/rejected_path. *)
      let beta_health_resp =
        read_via_protocol ~sender:(admit beta_tok) ~auth_token:beta_tok
          "masc://keepers/alpha/memory/health"
      in
      Alcotest.(check int) "non-matching worker gets Insufficient_scope (-32007) on health"
        (-32007) (error_code_exn beta_health_resp);
      List.iter (fun (label, tok) ->
        let health_json =
          Yojson.Safe.from_string
            (resource_text_exn
               (read_via_protocol ~sender:(admit tok) ~auth_token:tok
                  "masc://keepers/alpha/memory/health"))
        in
        Alcotest.(check string) (label ^ ": health schema") "keeper.memory.health.v1"
          Yojson.Safe.Util.(health_json |> member "schema" |> to_string);
        Alcotest.(check string) (label ^ ": health ordinary status") "readable"
          Yojson.Safe.Util.(health_json |> member "ordinary" |> member "status" |> to_string);
        let health_text = Yojson.Safe.to_string health_json in
        Alcotest.(check bool) (label ^ ": no detail field on health") false
          (String_util.contains_substring health_text "\"detail\"");
        Alcotest.(check bool) (label ^ ": no rejection field on health") false
          (String_util.contains_substring health_text "\"rejection\"");
        Alcotest.(check bool) (label ^ ": no rejected_path field on health") false
          (String_util.contains_substring health_text "\"rejected_path\""))
        [ "matching keeper", alpha_tok; "admin", admin_tok ];
      (* 6. Undecodable/unreadable errors on keeper/memory scrub free-text host paths/parser details. *)
      let ordinary_path = Memory_current.path_for_keepers_dir ~keepers_dir ~keeper_id:"alpha" in
      Fs_compat.save_file ordinary_path "{bad /secret/host/path/sentinel";
      let bad_mem_resp =
        read_via_protocol ~sender:(admit alpha_tok) ~auth_token:alpha_tok
          "masc://keepers/alpha/memory"
      in
      Alcotest.(check int) "undecodable keeper memory returns Internal_error"
        (Masc.Mcp_error_code.to_wire_code Masc.Mcp_error_code.Internal_error)
        (error_code_exn bad_mem_resp);
      Alcotest.(check string) "undecodable keeper memory uses closed message"
        "keeper ordinary memory snapshot undecodable"
        Yojson.Safe.Util.(bad_mem_resp |> member "error" |> member "message" |> to_string);
      Alcotest.(check bool) "undecodable error leaks no sentinel host path or detail" false
        (String_util.contains_substring (Yojson.Safe.to_string bad_mem_resp)
           "/secret/host/path/sentinel");
      (* 7. Truncated commit-log tail (>20 commits) with absent snapshot preserves accurate
            running [pre_tail_count] in forward fallback rather than resetting to 0. *)
      let log_only_keeper = "tailcount" in
      let log_only_path =
        Masc.Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id:log_only_keeper
      in
      let dummy_digest = Agent_core.Checkpoint_objects.digest_of_bytes "tailcount" in
      let dummy_log_id = Masc.Keeper_turn_log.Log_id.fresh () in
      let dummy_mark : Masc.Keeper_turn_log.mark =
        { trace = ""
        ; closed_messages = 0
        ; session = ""
        ; history_bytes = 0
        ; internal_bytes = 0
        ; chat_bytes = 0
        ; external_rows = 0
        }
      in
      let next_offset = ref 0 in
      for i = 1 to 25 do
        let f =
          Memory_types.observed
            ~claim:(Printf.sprintf "Tail count fact %d" i)
            ~category:Memory_types.Fact
            ~now:(1000.0 +. float_of_int i)
            ~origin:{ kind = Memory_types.Authored; trace_id = Printf.sprintf "tc-%d" i }
        in
        let commit : Masc.Librarian_log.commit =
          { seq = i
          ; at = 1000.0 +. float_of_int i
          ; basis = dummy_digest
          ; after = dummy_digest
          ; revision = i
          ; cause =
              Masc.Librarian_log.Direct
                { by = Masc.Librarian_effects.Keeper
                ; trace = Printf.sprintf "tc-%d" i
                ; write =
                    Masc.Librarian_direct.Remember
                      { claim = f.claim; category = f.category; basis = f.basis }
                }
          ; effects = { Masc.Librarian_effects.empty with added = [ f ] }
          ; turn_log = dummy_log_id
          ; turn_log_offset = 0
          ; covers_through = Masc.Librarian_log.Before_first
          ; covered = dummy_mark
          ; working_state = None
          }
        in
        match
          Masc.Librarian_log_store.append ~path:log_only_path ~at_end:!next_offset
            (Masc.Librarian_log.Committed commit)
        with
        | Ok { Masc.Librarian_log_store.new_end; _ } -> next_offset := new_end
        | Error _ -> Alcotest.fail "append tailcount commit log failed"
      done;
      let tc_health_json =
        Yojson.Safe.from_string
          (resource_text_exn
             (read_via_protocol ~sender:(admit admin_tok) ~auth_token:admin_tok
                "masc://keepers/tailcount/memory/health"))
      in
      let open Yojson.Safe.Util in
      Alcotest.(check string) "absent snapshot status" "missing"
        (tc_health_json |> member "ordinary" |> member "status" |> to_string);
      let tc_entries =
        tc_health_json |> member "journal" |> member "recent_entries" |> to_list
      in
      Alcotest.(check int) "recent_entries bounded to 20" 20 (List.length tc_entries);
      let oldest_entry = List.hd tc_entries in
      let newest_entry = List.hd (List.rev tc_entries) in
      Alcotest.(check int) "oldest retained commit (#6) starts from pre_tail_count=5" 5
        (oldest_entry |> member "retained_count" |> to_int);
      Alcotest.(check int) "newest retained commit (#25) has retained_count=24" 24
        (newest_entry |> member "retained_count" |> to_int))

let test_handle_request_resources_subscribe_requires_session () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  (match response with
   | `Assoc fields ->
       Alcotest.(check bool) "subscribe requires session" true
         (List.mem_assoc "error" fields)
   | _ -> Alcotest.fail "response not an object");
  cleanup_dir base_path

let test_handle_request_dashboard_ping_requires_session () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 242);
          ("method", `String "dashboard/ping");
          ("params", `Assoc []);
        ])
  in
  let response = Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw state request in
  Alcotest.(check bool) "ping requires ws session" true
    (String_util.contains_substring
       (Yojson.Safe.to_string response)
       "dashboard/ping requires a WebSocket session");
  cleanup_dir base_path

let test_handle_request_dashboard_ping_reports_unknown_ws_session () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 243);
          ("method", `String "dashboard/ping");
          ("params", `Assoc []);
        ])
  in
  let response =
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted
      ~clock
      ~sw
      ~mcp_session_id:"missing-dashboard-ws-session"
      state
      request
  in
  Alcotest.(check bool) "unknown ws session reported" true
    (String_util.contains_substring
       (Yojson.Safe.to_string response)
       "WebSocket session not found");
  cleanup_dir base_path

let test_handle_request_resources_subscribe_roundtrip () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.For_testing.create_state ~base_path () in
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
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~mcp_session_id:"session-spec" state
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
    Mcp_eio.handle_request ~sender:Mcp_eio.Unadmitted ~clock ~sw ~mcp_session_id:"session-spec" state
      unsubscribe_request
  in
  (match unsubscribe_response with
   | `Assoc fields ->
       Alcotest.(check bool) "unsubscribe ok" true
         (List.mem_assoc "result" fields)
   | _ -> Alcotest.fail "unsubscribe response not an object");
  cleanup_dir base_path

(* ===== Test Suites ===== *)

let state_tests = [
  "create_state", `Quick, test_create_state;
  "type compatibility", `Quick, test_type_compatibility;
  "eio context delegation", `Quick, test_eio_context_delegation;
  "eio context scoped restore", `Quick, test_eio_context_with_test_env_restores;
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

let test_world_memory_mcp_auth_active_only_and_limit_clamps () =
  let module Resource = Masc.Mcp_server_eio_resource in
  let module WM_types = Masc.World_memory_types in
  let module WM_store = Masc.World_memory_store in
  let module WM_curator = Masc.World_memory_curator in
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> cleanup_dir base_path) @@ fun () ->
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let state = Mcp_eio.For_testing.create_state ~base_path () in
  let config = Masc.Mcp_server.workspace_config state in
  ignore (Masc.Workspace.init config ~agent_name:(Some "op-admin"));

  (* Populate World Memory with:
     - a shared workspace fact from keeper-alpha (carrying local source_fact_ids)
     - a private-scoped keeper:alpha fact
     - a superseded terminal fact *)
  let shared_claim = "Shared workspace build invariant" in
  let shared_id = WM_types.fact_id_of_claim ~scope:"workspace" ~claim:shared_claim in
  ignore
    (WM_store.upsert_fact ~base_path ~now:10.0 ~actor:"librarian:keeper-alpha"
       ~fact_id:shared_id ~claim:shared_claim ~category:Masc.Keeper_memory_os_types.Fact
       ~facets:[ "build" ] ~scope:"workspace"
       ~provenance:(Proposed_by { keeper_id = "keeper-alpha"; source_fact_ids = [ "sha256:alpha-local-1" ] })
       ~lifecycle:Canonical
     |> Result.get_ok);
  let private_claim = "Alpha private working note" in
  let private_id = WM_types.fact_id_of_claim ~scope:"keeper:keeper-alpha" ~claim:private_claim in
  ignore
    (WM_store.upsert_fact ~base_path ~now:11.0 ~actor:"librarian:keeper-alpha"
       ~fact_id:private_id ~claim:private_claim ~category:Masc.Keeper_memory_os_types.Fact
       ~facets:[ "private" ] ~scope:"keeper:keeper-alpha"
       ~provenance:(Proposed_by { keeper_id = "keeper-alpha"; source_fact_ids = [ "sha256:alpha-priv-1" ] })
       ~lifecycle:Working
     |> Result.get_ok);
  let mixed_case_private_claim = "Alpha mixed-case private note" in
  let mixed_case_private_id =
    WM_types.fact_id_of_claim ~scope:"Keeper:keeper-alpha" ~claim:mixed_case_private_claim
  in
  ignore
    (WM_store.upsert_fact ~base_path ~now:11.2 ~actor:"librarian:keeper-alpha"
       ~fact_id:mixed_case_private_id ~claim:mixed_case_private_claim
       ~category:Masc.Keeper_memory_os_types.Fact
       ~facets:[ "private" ] ~scope:"Keeper:keeper-alpha"
       ~provenance:(Proposed_by { keeper_id = "keeper-alpha"; source_fact_ids = [ "sha256:alpha-priv-2" ] })
       ~lifecycle:Working
     |> Result.get_ok);
  let upper_private_claim = "Alpha UPPER private note" in
  let upper_private_id =
    WM_types.fact_id_of_claim ~scope:"PRIVATE:keeper-alpha" ~claim:upper_private_claim
  in
  ignore
    (WM_store.upsert_fact ~base_path ~now:11.4 ~actor:"librarian:keeper-alpha"
       ~fact_id:upper_private_id ~claim:upper_private_claim
       ~category:Masc.Keeper_memory_os_types.Fact
       ~facets:[ "private" ] ~scope:"PRIVATE:keeper-alpha"
       ~provenance:(Proposed_by { keeper_id = "keeper-alpha"; source_fact_ids = [] })
       ~lifecycle:Working
     |> Result.get_ok);
  (* Link shared_id -> private_id to verify non-admin fact reads withhold edges
     pointing to invisible sibling private facts. *)
  ignore
    (WM_store.add_edge ~base_path ~now:11.6 ~actor:"world_curator"
       ~from_fact_id:shared_id ~to_fact_id:private_id
       ~kind:Refines ~reason:"private-peer-edge-reason"
     |> Result.get_ok);
  let obsolete_claim = "Obsolete claim to supersede" in
  let obsolete_id = WM_types.fact_id_of_claim ~scope:"workspace" ~claim:obsolete_claim in
  ignore
    (WM_store.upsert_fact ~base_path ~now:12.0 ~actor:"librarian:keeper-alpha"
       ~fact_id:obsolete_id ~claim:obsolete_claim ~category:Masc.Keeper_memory_os_types.Fact
       ~facets:[ "old" ] ~scope:"workspace"
       ~provenance:(Proposed_by { keeper_id = "keeper-alpha"; source_fact_ids = [] })
       ~lifecycle:Working
     |> Result.get_ok);
  ignore
    (WM_curator.supersede_fact_sync ~base_path ~now:13.0 ~actor:"world_curator"
       ~old_fact_id:obsolete_id ~new_fact_id:shared_id ~reason:"superseded"
     |> Result.get_ok);

  let read_direct ?caller id_num uri =
    Resource.handle_read_resource_eio ?caller state (`Int id_num)
      (Some (`Assoc [ ("uri", `String uri) ]))
  in
  let error_code_of resp =
    Yojson.Safe.Util.(resp |> member "error" |> member "code" |> to_int)
  in
  let text_of resp =
    Yojson.Safe.Util.(
      resp |> member "result" |> member "contents" |> to_list |> List.hd |> member "text" |> to_string)
  in

  (* 1. Anonymous_reader (and omitted ?caller) fail closed with -32001 on ALL World_memory_* URIs. *)
  List.iteri
    (fun i uri ->
       Alcotest.(check int) ("omitted caller refused on " ^ uri) (-32001)
         (error_code_of (read_direct (100 + i) uri));
       Alcotest.(check int) ("explicit Anonymous_reader refused on " ^ uri) (-32001)
         (error_code_of (read_direct ~caller:Resource.Anonymous_reader (200 + i) uri)))
    [ "masc://world-memory/claims"
    ; "masc://world-memory/digest"
    ; "masc://world-memory/index"
    ; "masc://world-memory/facts/" ^ shared_id
    ; "masc://world-memory/log"
    ];

  (* 2. Non-admin Authenticated_reader ("keeper-beta"):
        - blocked (-32007) on world-memory/log and keeper:keeper-alpha fact
        - sees shared claims with cross-Keeper source_fact_ids scrubbed to [] *)
  let beta_caller =
    Resource.Authenticated_reader
      { agent_name = "keeper-beta"
      ; board_reader = Masc_board_handlers.Board_access.named "keeper-beta"
      }
  in
  Alcotest.(check int) "non-admin blocked on world-memory/log (-32007)" (-32007)
    (error_code_of (read_direct ~caller:beta_caller 301 "masc://world-memory/log"));
  Alcotest.(check int) "non-admin blocked on sibling private fact scope (-32007)" (-32007)
    (error_code_of (read_direct ~caller:beta_caller 302 ("masc://world-memory/facts/" ^ private_id)));
  Alcotest.(check int) "non-admin blocked on mixed-case Keeper: scope (-32007)" (-32007)
    (error_code_of
       (read_direct ~caller:beta_caller 306 ("masc://world-memory/facts/" ^ mixed_case_private_id)));
  Alcotest.(check int) "non-admin blocked on uppercase PRIVATE: scope (-32007)" (-32007)
    (error_code_of
       (read_direct ~caller:beta_caller 307 ("masc://world-memory/facts/" ^ upper_private_id)));
  let alpha_caller =
    Resource.Authenticated_reader
      { agent_name = "keeper-alpha"
      ; board_reader = Masc_board_handlers.Board_access.named "keeper-alpha"
      }
  in
  let alpha_mixed =
    Yojson.Safe.from_string
      (text_of
         (read_direct ~caller:alpha_caller 308 ("masc://world-memory/facts/" ^ mixed_case_private_id)))
  in
  Alcotest.(check string) "owning keeper reads own mixed-case Keeper: fact" mixed_case_private_id
    Yojson.Safe.Util.(alpha_mixed |> member "fact" |> member "fact_id" |> to_string);
  let beta_claims =
    Yojson.Safe.from_string (text_of (read_direct ~caller:beta_caller 303 "masc://world-memory/claims"))
  in
  let beta_claim_list = Yojson.Safe.Util.(beta_claims |> member "claims" |> to_list) in
  List.iter
    (fun (label, hidden_id) ->
       Alcotest.(check bool) (label ^ " excluded from beta claims") false
         (List.exists
            (fun f -> String.equal Yojson.Safe.Util.(f |> member "fact_id" |> to_string) hidden_id)
            beta_claim_list))
    [ "private keeper:keeper-alpha fact", private_id
    ; "mixed-case Keeper:keeper-alpha fact", mixed_case_private_id
    ; "uppercase PRIVATE:keeper-alpha fact", upper_private_id
    ];
  let beta_briefing_text =
    Yojson.Safe.Util.(beta_claims |> member "briefing" |> member "text" |> to_string)
  in
  Alcotest.(check bool) "private keeper:keeper-alpha claim absent from claims briefing" false
    (String_util.contains_substring beta_briefing_text private_claim);
  let beta_digest =
    Yojson.Safe.from_string (text_of (read_direct ~caller:beta_caller 305 "masc://world-memory/digest"))
  in
  let beta_digest_rendered =
    Yojson.Safe.Util.(beta_digest |> member "digest" |> member "rendered" |> to_string)
  in
  Alcotest.(check bool) "private keeper:keeper-alpha claim absent from world-memory/digest" false
    (String_util.contains_substring beta_digest_rendered private_claim);
  let beta_shared_fact =
    Yojson.Safe.from_string
      (text_of (read_direct ~caller:beta_caller 304 ("masc://world-memory/facts/" ^ shared_id)))
  in
  let beta_source_ids =
    Yojson.Safe.Util.(
      beta_shared_fact |> member "fact" |> member "provenance" |> member "source_fact_ids" |> to_list)
  in
  Alcotest.(check int) "cross-Keeper source_fact_ids scrubbed for non-admin reader" 0
    (List.length beta_source_ids);
  let beta_shared_edges = Yojson.Safe.Util.(beta_shared_fact |> member "edges" |> to_list) in
  Alcotest.(check bool) "non-admin fact read withholds edge pointing to sibling private fact" false
    (List.exists
       (fun e -> String.equal Yojson.Safe.Util.(e |> member "to_fact_id" |> to_string) private_id)
       beta_shared_edges);
  Alcotest.(check bool) "non-admin fact read retains workspace-scoped edge" true
    (List.exists
       (fun e -> String.equal Yojson.Safe.Util.(e |> member "to_fact_id" |> to_string) obsolete_id)
       beta_shared_edges);

  (* 3. Operator_admin sees world-memory/log and full provenance, while Superseded facts
        remain filtered out by default (-32602). *)
  let admin_log =
    Yojson.Safe.from_string
      (text_of (read_direct ~caller:Resource.Operator_admin 401 "masc://world-memory/log"))
  in
  Alcotest.(check bool) "admin reads world-memory/log" true
    (Yojson.Safe.Util.(admin_log |> member "last_committed_seq" |> to_int) >= 1);
  let admin_shared =
    Yojson.Safe.from_string
      (text_of (read_direct ~caller:Resource.Operator_admin 402 ("masc://world-memory/facts/" ^ shared_id)))
  in
  Alcotest.(check int) "admin retains full source_fact_ids" 1
    (List.length
       Yojson.Safe.Util.(
         admin_shared |> member "fact" |> member "provenance" |> member "source_fact_ids" |> to_list));
  Alcotest.(check int) "Superseded fact filtered out by default (-32602)" (-32602)
    (error_code_of
       (read_direct ~caller:Resource.Operator_admin 403 ("masc://world-memory/facts/" ^ obsolete_id)));

  (* 4. ?limit=1000000000 clamped to <= 500 on Messages_* and Events_*, and corrupt/unreadable
        message files are skipped without raising (honoring .mli Never raises). *)
  let msgs_dir = Masc.Workspace.messages_dir config in
  Fs_compat.mkdir_p msgs_dir;
  for i = 1 to 505 do
    let msg : Masc_domain.message =
      { request_id = Printf.sprintf "req-%d" i
      ; seq = i
      ; from_agent = "alpha"
      ; msg_type = "broadcast"
      ; content = Printf.sprintf "msg-%d" i
      ; mention = None
      ; mention_delivery = Masc_domain.Mention_passive
      ; timestamp = "2026-11-22T00:00:00Z"
      ; expires_at = None
      ; trace_context = None
      }
    in
    Fs_compat.save_file
      (Filename.concat msgs_dir (Printf.sprintf "%06d_msg.json" i))
      (Yojson.Safe.to_string (Masc_domain.message_to_yojson msg))
  done;
  (* Inject a corrupt JSON file and a subdirectory into messages_dir to verify Never raises. *)
  Fs_compat.save_file (Filename.concat msgs_dir "999999_corrupt.json") "{broken-json";
  Unix.mkdir (Filename.concat msgs_dir "999998_dir.json") 0o755;
  let msgs_resp =
    read_direct ~caller:Resource.Operator_admin 501 "masc://messages.json?limit=1000000000"
  in
  let msgs_json = Yojson.Safe.from_string (text_of msgs_resp) |> Yojson.Safe.Util.to_list in
  Alcotest.(check int) "messages.json clamps ?limit=1000000000 to 500 and survives corrupt files"
    500 (List.length msgs_json);
  let events_dir = Filename.concat (Filename.concat base_path ".masc") "events" in
  Fs_compat.mkdir_p events_dir;
  let event_lines =
    String.concat "\n" (List.init 510 (fun i -> Printf.sprintf {|{"seq":%d}|} i)) ^ "\n"
  in
  Fs_compat.save_file (Filename.concat events_dir "events.jsonl") event_lines;
  let events_resp =
    read_direct ~caller:Resource.Operator_admin 502 "masc://events.json?limit=1000000000"
  in
  let events_json = Yojson.Safe.from_string (text_of events_resp) |> Yojson.Safe.Util.to_list in
  Alcotest.(check bool) "events.json clamps ?limit=1000000000 to <= 500" true
    (List.length events_json <= 500)

let eio_tests = [
  "world memory MCP auth, active-only filtering, and limit clamps", `Quick,
    test_world_memory_mcp_auth_active_only_and_limit_clamps;
  "handle initialize", `Quick, test_handle_request_initialize;
  "handle initialize counteroffers a legacy version", `Quick,
    test_handle_request_initialize_counteroffers_legacy_version;
  "handle server/discover advertises 2026", `Quick,
    test_handle_request_server_discover_2026;
  "stdio admission and subscription cancellation", `Quick,
    test_stdio_admission_and_subscription_cancellation;
  "stdio ping is answered during a long tool call", `Quick,
    test_stdio_ping_is_answered_during_a_long_tool_call;
  "stdio cancellation stops a running tool call", `Quick,
    test_stdio_cancellation_stops_a_running_tool_call;
  "stdio requires enabled guard", `Quick, test_stdio_requires_enabled_guard;
  "stdio EOF drains committed response", `Quick,
    test_stdio_eof_drains_committed_response;
  "stdio parent cancel drains external subscription send", `Quick,
    test_stdio_parent_cancel_drains_external_subscription_send;
  "stdio write failure never appends another frame", `Quick,
    test_stdio_write_failure_never_appends_another_frame;
  "subscription retirement keeps drain authority", `Quick,
    test_subscription_retirement_keeps_drain_authority;
  "stdio EOF reports external send failure", `Quick,
    test_stdio_eof_reports_external_send_failure;
  "stdio prior failure precedes drain cancellation", `Quick,
    test_stdio_prior_failure_precedes_drain_cancellation;
  "stdio subscription requires authentication", `Quick,
    test_stdio_subscription_requires_auth;
  "stdio legacy ping and modern removal", `Quick,
    test_stdio_legacy_ping_and_modern_removal;
  "stdio rejects unissued modern continuations", `Quick,
    test_stdio_rejects_unissued_modern_continuations;
  "stdio modern identity and legacy session isolation", `Quick,
    test_stdio_modern_calls_do_not_reuse_legacy_identity;
  "stdio forwards external credential", `Quick,
    test_stdio_forwards_external_credential;
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
  "handle resources/list includes tool-help", `Quick, test_handle_request_resources_list_includes_tool_help;
  "handle resources/list includes wiki pages", `Quick,
    test_handle_request_resources_list_includes_wiki_pages;
  "handle resources/list rejects unknown field", `Quick,
    test_handle_request_resources_list_rejects_unknown_field;
  "handle resources/list paginates", `Quick,
    test_handle_request_resources_list_paginates;
  "listed resource uris have readers", `Quick,
    test_listed_resource_uris_have_readers;
  "handle resources/read tool-help", `Quick, test_handle_request_tool_help_resource_read;
  "handle resources/read matrix", `Quick, test_handle_request_resources_read_matrix;
  "handle resources/read keeper memory readership and health", `Quick,
    test_handle_request_keeper_memory_access_and_readership;
  "handle resources/templates/list rejects invalid cursor", `Quick,
    test_handle_request_resources_templates_rejects_invalid_cursor;
  "handle resources/subscribe requires session", `Quick,
    test_handle_request_resources_subscribe_requires_session;
  "handle dashboard/ping requires session", `Quick,
    test_handle_request_dashboard_ping_requires_session;
  "handle dashboard/ping reports unknown ws session", `Quick,
    test_handle_request_dashboard_ping_reports_unknown_ws_session;
  "handle resources/subscribe roundtrip", `Quick,
    test_handle_request_resources_subscribe_roundtrip;
  "handle tools/list filters requested names", `Quick,
    test_handle_request_tools_list_rejects_nonstandard_names_filter;
  "handle initialize managed profile", `Quick,
    test_handle_request_initialize_managed_profile;
  "handle tools/list managed profile", `Quick,
    test_handle_request_tools_list_managed_profile;
  "handle tools/list operator profile", `Quick,
    test_handle_request_tools_list_operator_profile;
  "handle tools/list include hidden metadata", `Quick,
    test_handle_request_tools_list_include_hidden_metadata;
  "handle tools/list include usage metadata", `Quick,
    test_handle_request_tools_list_include_usage_metadata;
  "handle tools/list paginates", `Quick, test_handle_request_tools_list_paginates;
  "handle batch request rejected", `Quick, test_handle_request_batch_rejected;
  "handle jsonrpc response returns null", `Quick,
    test_handle_request_jsonrpc_response_returns_null;
  "reject non-operator tool on operator profile", `Quick,
  test_handle_request_tools_call_operator_profile_rejects_non_operator;
  "handle tools/call managed profile rejects hidden claim alias", `Quick,
    test_handle_request_tools_call_managed_profile_rejects_hidden_claim_alias;
  "handle tools/call missing params records duration", `Quick,
    test_handle_request_tools_call_missing_params_records_duration;
  "handle tools/call managed invalid arguments record duration", `Quick,
    test_handle_request_tools_call_managed_invalid_arguments_records_duration;
  "handle tools/call transition claim guidance", `Quick,
    test_handle_request_tools_call_transition_claim_guidance;
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
  "verified internal Keeper Lane access", `Quick,
    test_internal_keeper_lane_access_requires_verified_runtime_and_keeper;
  "door bearer answers caller identity as the token did", `Quick,
    test_door_bearer_answers_caller_identity_as_the_token_did;
  "executor authorizes the owner from the door answer", `Quick,
    test_executor_authorizes_the_owner_from_the_door_answer;
  "handle tools/list internal keeper runtime hides keeper internal tools", `Quick,
    test_handle_request_tools_list_internal_keeper_runtime_hides_keeper_internal_tools;
  "handle tools/call internal keeper runtime rejects unknown execute", `Quick,
    test_handle_request_tools_call_internal_keeper_runtime_rejects_unknown_execute;
  "handle invalid json", `Quick, test_handle_request_invalid_json;
  "handle method not found", `Quick, test_handle_request_method_not_found;
  (* TRPG tool tests removed — modules archived *)
  "explicit agent_name not overridden", `Quick, test_execute_tool_explicit_agent_name_not_overridden;
  "tool-domain agent_name does not reuse bound nickname", `Quick,
    test_execute_tool_domain_agent_name_does_not_reuse_joined_nickname;
  "generated agent_name uses token identity", `Quick,
    test_execute_tool_generated_agent_name_uses_token_identity;
  "actor mismatch reports typed code", `Quick,
    test_execute_tool_actor_mismatch_reports_typed_code;
  "internal _agent_name is caller identity", `Quick,
    test_execute_tool_internal_agent_name_is_caller_identity;
  "explicit generated alias claim_next not rewritten by token", `Quick,
    test_execute_tool_explicit_generated_alias_claim_next_not_rewritten_by_token;
  "explicit generated alias transition not rewritten by token", `Quick,
    test_execute_tool_explicit_generated_alias_transition_not_rewritten_by_token;
  "hyphenated generated alias claim_next rejected without mutation", `Quick,
    test_execute_tool_hyphenated_generated_alias_claim_next_rejected_without_mutation;
  "claim_next auth preflight blocks mutation", `Quick,
    test_execute_tool_claim_next_requires_auth_before_mutation;
  "transition auth preflight blocks mutation", `Quick,
    test_execute_tool_transition_requires_auth_before_mutation;
  "add_task admin token works without join", `Quick,
    test_execute_tool_add_task_with_admin_token_without_join;
  "http auth token overrides stale argument token", `Quick,
    test_execute_tool_http_auth_token_overrides_stale_argument_token;
  "argument token ignored without http auth", `Quick,
    test_execute_tool_argument_token_ignored_without_http_auth;
  "without mcp session uses generated identity", `Quick,
    test_execute_tool_without_mcp_session_uses_generated_identity;
]

let () =
  Alcotest.run "Mcp_server_eio" [
    "state", state_tests;
    "protocol", protocol_tests;
    "response", response_tests;
    "eio", eio_tests;
  ]
