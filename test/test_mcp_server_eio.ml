module Types = Masc_domain

(** Test suite for Mcp_server_eio module

    Tests the Eio-native MCP server implementation.
    Uses Eio_main.run for async test context.
*)

module Mcp_eio = Masc.Mcp_server_eio
module Mcp = Masc.Mcp_server
module Mcp_server = Masc.Mcp_server
module Config = Masc.Config
module Tool_result = Tool_result
module Keeper_types = Keeper_types
module Keeper_identity = Masc.Keeper_identity
module Keeper_registry = Masc.Keeper_registry
module Masc_log = Log

let () =
  Mirage_crypto_rng_unix.use_default ();
  let (_operator_force_link : unit) = Operator_tool.force_link in
  let (_dashboard_ws_sessions : int) = Server_mcp_transport_ws.session_count () in
  Atomic.set Workspace_hooks.get_default_runtime_id_fn (fun () -> "test.local");
  Atomic.set Workspace_hooks.get_cross_verifier_runtime_id_fn (fun () -> None)

let () =
  (* These process-global registries are installed by module initializers in the
     production server path.  Force them in this standalone test executable so
     profile-specific fixtures do not depend on link/load order. *)
  ignore (Operator_tool.remote_tool_names : string list);
  ignore (Server_mcp_transport_ws.session_count : unit -> int);
  (* The transition-done guidance fixture reaches completion review; production
     wires this runtime hook during startup.  A fixed dummy id lets the test
     exercise guidance behavior without booting runtime.toml. *)
  Atomic.set Workspace_hooks.get_default_runtime_id_fn (fun () -> "test-evaluator-runtime")

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

let make_keeper_meta ?agent_name ?tool_access name =
  let agent_name =
    Option.value agent_name
      ~default:(Keeper_identity.keeper_agent_name name)
  in
  let tool_access_fields =
    match tool_access with
    | Some access -> [ ("tool_access", access) ]
    | None -> []
  in
  let json =
    `Assoc
      ([
         ("name", `String name);
         ("agent_name", `String agent_name);
         ("trace_id", `String ("trace-test-" ^ name));
         ("goal", `String "test goal");
       ]
       @ tool_access_fields)
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
    base_path (Mcp_server.workspace_config state).base_path;
  cleanup_dir base_path

let test_type_compatibility () =
  (* Verify Mcp_server_eio.server_state is same type as Mcp_server.server_state *)
  let base_path = temp_dir () in
  let state : Mcp_eio.server_state = Mcp_eio.create_state ~test_mode:true ~base_path () in
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
  Alcotest.(check bool) "valid 2.0" true (Masc.Mcp_server.is_jsonrpc_v2 valid);
  Alcotest.(check bool) "invalid 1.0" false (Masc.Mcp_server.is_jsonrpc_v2 invalid);
  Alcotest.(check bool) "no version" false (Masc.Mcp_server.is_jsonrpc_v2 no_version)

let test_jsonrpc_request_parsing () =
  let json = `Assoc [
    ("jsonrpc", `String "2.0");
    ("id", `Int 1);
    ("method", `String "initialize");
    ("params", `Assoc []);
  ] in
  match Masc.Mcp_server.jsonrpc_request_of_yojson json with
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
  (match Masc.Mcp_server.jsonrpc_request_of_yojson with_id with
   | Ok req -> Alcotest.(check bool) "with id" false (Masc.Mcp_server.is_notification req)
   | Error _ -> Alcotest.fail "parse error");
  (match Masc.Mcp_server.jsonrpc_request_of_yojson without_id with
   | Ok req -> Alcotest.(check bool) "without id" true (Masc.Mcp_server.is_notification req)
   | Error _ -> Alcotest.fail "parse error")

let test_protocol_version () =
  let params = Some (`Assoc [("protocolVersion", `String "2025-06-18")]) in
  let version = Masc.Mcp_server.protocol_version_from_params params in
  Alcotest.(check string) "version extracted" "2025-06-18" version;

  (match Mcp.validate_protocol_version "2025-06-18" with
   | Ok version ->
       Alcotest.(check string) "2025-06-18 is supported" "2025-06-18" version
   | Error msg -> Alcotest.fail msg);

  let normalized = Masc.Mcp_server.normalize_protocol_version "unknown" in
  Alcotest.(check string) "normalized to default" "2025-11-25" normalized;

  match Mcp.validate_protocol_version "unknown" with
  | Error msg ->
      Alcotest.(check bool) "unsupported version rejected" true
        (contains_substring msg "Unsupported protocolVersion")
  | Ok _ -> Alcotest.fail "expected unsupported protocol version to be rejected"

(* ===== Unit Tests for Response Builders ===== *)

let test_make_response () =
  let response = Masc.Mcp_server.make_response ~id:(`Int 42) (`String "result") in
  match response with
  | `Assoc fields ->
      let id = List.assoc "id" fields in
      let result = List.assoc "result" fields in
      Alcotest.(check bool) "has jsonrpc" true (List.mem_assoc "jsonrpc" fields);
      Alcotest.(check bool) "id is 42" true (id = `Int 42);
      Alcotest.(check bool) "result is string" true (result = `String "result")
  | _ -> Alcotest.fail "not an object"

let test_make_error () =
  let response = Masc.Mcp_server.make_error ~id:(`Int 1) (-32600) "Invalid Request" in
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

let test_handle_request_server_discover_2026 () =
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
  let response = Mcp_eio.handle_request ~clock ~sw state request in
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let sid = "mcp-managed-alias-claim" in
  let init_result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
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
    Mcp_eio.handle_request ~clock ~sw ~profile:Mcp_eio.Managed_agent
      ~mcp_session_id:sid
      ~otel_mcp_protocol_version:"2025-06-18"
      ~otel_transport_context:(Otel_dispatch_hook.http_transport_context ~protocol_version:"2")
      state request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "removed alias rejected" true
    (contains_substring response_text
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
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
    Mcp_eio.handle_request
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
    (contains_substring response_text "Missing params");
  Alcotest.(check (float 0.0001)) "missing params records duration count"
    1.0
    (Masc.Otel_metric_store.metric_value_or_zero (metric_name ^ "_count") ~labels ()
     -. before_count);
  cleanup_dir base_path

let test_handle_request_tools_call_managed_translation_error_records_duration () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Mcp_eio.set_net (Eio.Stdenv.net env);
  Mcp_eio.set_clock (Eio.Stdenv.clock env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
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
    Mcp_eio.handle_request
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
  Alcotest.(check bool) "translation error is returned" true
    (contains_substring response_text "managed agent tool translation failed");
  Alcotest.(check (float 0.0001)) "translation error records duration count"
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  Masc.Auth.disable_auth base_path;
  let sid = "mcp-transition-claim-guidance" in
  let init_result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
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
                      ("agent_name", `String "codex");
                      ("task_id", `String "task-001");
                      ("agent_name", `String "codex");
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
    (Masc.Task.Planning_eio.get_current_task (Mcp_server.workspace_config state));
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
  Masc.Auth.disable_auth base_path;
  let sid = "mcp-transition-done-guidance" in
  let init_result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
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
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"transition-done"
       ~priority:2 ~description:"");
  let claim_result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
      ~name:"masc_transition"
      ~arguments:
        (`Assoc
          [
            ("agent_name", `String "codex");
            ("task_id", `String "task-001");
            ("agent_name", `String "codex");
            ("action", `String "claim");
          ])
  in
  Alcotest.(check bool) "claim setup success" true (Tool_result.is_success claim_result);
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
                      ("agent_name", `String "codex");
                      ("task_id", `String "task-001");
                      ("agent_name", `String "codex");
                      ("action", `String "done");
                      ("notes", `String "Completed task and verified output");
                    ] );
              ] );
        ])
  in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:sid state request
  in
  let envelope = result_envelope_exn response in
  Alcotest.(check string) "done result status" "ok"
    (match List.assoc_opt "status" envelope with
     | Some (`String status) -> status
     | _ -> Alcotest.fail "status missing");
  Alcotest.(check bool) "done result summary" true
    (match List.assoc_opt "summary" envelope with
     | Some (`String summary) ->
       contains_substring summary "claimed" && contains_substring summary "done"
     | _ -> false);
  let steps = workflow_next_step_names response in
  let task =
    Masc.Workspace.get_tasks_raw (Mcp_server.workspace_config state)
    |> List.find_opt (fun (task : Masc_domain.task) -> String.equal task.id "task-001")
  in
  (match task with
   | Some { task_status = Masc_domain.Done _; _ } -> ()
   | Some { task_status; _ } ->
       Alcotest.failf "task-001 should be done, got %s"
         (Masc_domain.task_status_to_string task_status)
   | None -> Alcotest.fail "task-001 missing");
  Alcotest.(check (option string)) "done clears current_task" None
    (Masc.Task.Planning_eio.get_current_task (Mcp_server.workspace_config state));
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
  Masc.Auth.disable_auth base_path;
  let sid = "mcp-deprecated-claim-alias" in
  let init_result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:sid state
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
                      ("agent_name", `String "codex");
                    ] );
              ] );
        ])
  in
  let response =
    Mcp_eio.handle_request ~clock ~sw ~mcp_session_id:sid state request
  in
  let response_text = Yojson.Safe.to_string response in
  Alcotest.(check bool) "missing action rejected" true
    (contains_substring response_text "action"
     && contains_substring response_text "MISSING");
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

(* Governance status tool is no longer dispatched *)

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
      ~auth_token:None ~internal_keeper_runtime:false
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
      ~auth_token:None ~internal_keeper_runtime:false
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in

  let status_result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
      ~name:"masc_auth_status"
      ~arguments:(`Assoc [("agent_name", `String "dashboard-eager-manta")])
  in
  (* masc_auth_status tool pruned from registry; dispatch should fail. *)
  Alcotest.(check bool) "auth status fails (tool pruned)" false (Tool_result.is_success status_result);

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

let check_auth_preflight_result ~tool_name ok msg =
  Alcotest.(check bool) (tool_name ^ " rejected before handler") false ok;
  Alcotest.(check bool) (tool_name ^ " reports auth/credential blocker") true
    (contains_substring msg "Token required"
     || contains_substring msg "Unauthorized"
     || contains_substring msg "No credential")

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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"stable-admin" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"explicit-alias-claim-next"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~auth_token:raw_token state
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"stable-admin" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"explicit-alias-transition"
       ~priority:2 ~description:"");
  let result =
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc.Auth.create_token base_path ~agent_name:"qa-king" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"hyphenated-generated-alias-claim-next"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock ~mcp_session_id:"sid-hyphenated-generated-alias"
      ~auth_token:raw_token state
      ~name:"keeper_task_claim"
      ~arguments:(`Assoc [ ("agent_name", `String "qa-king-warm-heron") ])
  in
  Alcotest.(check bool) "claim_next rejected by public MCP path" false
    (Tool_result.is_success result);
  Alcotest.(check bool) "claim_next points to in-process task handler" true
    (contains_substring
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"uncredentialed-agent" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"claim-next-auth-preflight"
       ~priority:2 ~description:"");
  let result =
    Mcp_eio.execute_tool_eio ~sw ~clock state
      ~name:"keeper_task_claim"
      ~arguments:(`Assoc [ ("agent_name", `String "uncredentialed-agent") ])
  in
  check_auth_preflight_result ~tool_name:"keeper_task_claim"
    (Tool_result.is_success result) ((Tool_result.message result));
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  ignore (Masc.Workspace.bind_session (Mcp_server.workspace_config state) ~agent_name:"uncredentialed-agent" ~capabilities:[] ());
  ignore
    (Masc.Workspace.add_task (Mcp_server.workspace_config state) ~title:"transition-auth-preflight"
       ~priority:2 ~description:"");
  let result =
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
  check_auth_preflight_result ~tool_name:"masc_transition"
    (Tool_result.is_success result) ((Tool_result.message result));
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
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:None);
  ignore (Masc.Auth.enable_auth base_path ~require_token:true ~agent_name:"bootstrap-admin");
  let raw_token =
    match Masc.Auth.create_token base_path ~agent_name:"stable-admin" ~role:Masc_domain.Admin with
    | Ok (token, _cred) -> token
    | Error e -> Alcotest.fail (Masc_domain.masc_error_to_string e)
  in
  let result =
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
  Alcotest.(check bool) "add_task succeeds" true (Tool_result.is_success result);
  Alcotest.(check bool) "response mentions added task" true
    (contains_substring ((Tool_result.message result)) "Added task-001");
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
      ~auth_token:(Some "http-auth-token")
      ~internal_keeper_runtime:false
      ~workspace_initialized:(fun () -> true)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  Alcotest.(check (option string))
    "http auth token wins over stale argument token"
    (Some "http-auth-token")
    result.token;
  cleanup_dir base_path

let test_execute_tool_legacy_argument_token_ignored_without_http_auth () =
  let base_path = temp_dir () in
  let config = Masc.Workspace.default_config base_path in
  let identity =
    test_agent_identity
      ~uuid:"legacy-token-ignored-test"
      ~session_key:"legacy-token-ignored-session"
  in
  let result =
    Masc.Mcp_server_eio_caller_identity.resolve ~config
      ~tool_name:"masc_status"
      ~arguments:(`Assoc [ ("token", `String "legacy-argument-token") ])
      ~identity ~cached_resolved_agent:None
      ~auth_token:None ~internal_keeper_runtime:false
      ~workspace_initialized:(fun () -> true)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  Alcotest.(check (option string))
    "legacy argument token ignored without HTTP auth"
    None
    result.token;
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
      ~arguments:(`Assoc [ ("message", `String "generated identity check") ])
      ~identity ~cached_resolved_agent:None
      ~auth_token:None ~internal_keeper_runtime:false
      ~workspace_initialized:(fun () -> true)
      ~log_mcp_exn:(fun ~label:_ _ -> ())
  in
  Alcotest.(check string)
    "generated fallback"
    "agent-nosess00"
    result.agent_name;

  cleanup_dir base_path

(* Legacy governance convo tools are stubs; workspace-scoped test removed *)

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
      let keeper_agent_name = Keeper_identity.keeper_agent_name keeper_name in
      ignore
        (Keeper_registry.register ~base_path keeper_name
           (make_keeper_meta ~agent_name:keeper_agent_name keeper_name));
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
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
          Masc.Keeper_registry_tool_usage_persistence.flush ~base_path keeper_name;
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
  Alcotest.(check bool) "mentions unknown keeper internal tool" true
    (contains_substring msg "Unknown tool: keeper_time_now");
  Alcotest.(check bool) "does not include did-you-mean suggestion" false
    (contains_substring msg "did you mean");
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
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let token = Masc.Auth.ensure_internal_keeper_token base_path in
      let request = Yojson.Safe.to_string (`Assoc [
        ("jsonrpc", `String "2.0");
        ("id", `Int 119);
        ("method", `String "tools/list");
        ("params", `Assoc []);
      ]) in
      let response =
        Mcp_eio.handle_request ~clock ~sw ~auth_token:token
          ~internal_keeper_runtime:true state request
      in
      let names = tool_names_from_list_response response in
      (* internal_keeper_runtime no longer exposes keeper-internal tools to
         tools/list: the Agent_internal surface was removed and
         include_agent_internal adds no schema (see
         mcp_server_eio_tool_profile.ml), so the Full-profile is_public_mcp
         filter still drops them. Pin that tool_execute and masc_session stay
         hidden even when the flag is set. A prior half-finished refactor left a
         contradictory "tool_execute listed = true" assertion here against the
         identical [List.mem] expression; it could never co-pass with the
         hidden check below and is removed. *)
      Alcotest.(check bool) "retired tool_execute hidden" false
        (List.mem "tool_execute" names);
      Alcotest.(check bool) "system internal still hidden" false
        (List.mem "masc_session" names))

let test_handle_request_tools_call_internal_keeper_runtime_rejects_retired_execute
    () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.clear ();
      cleanup_dir base_path)
    (fun () ->
      Keeper_registry.clear ();
      let keeper_name = "sangsu" in
      let keeper_agent_name = Keeper_identity.keeper_agent_name keeper_name in
      let tool_access =
        `List [ `String "tool_execute"; `String "keeper_time_now" ]
      in
      ignore
        (Keeper_registry.register ~base_path keeper_name
           (make_keeper_meta ~agent_name:keeper_agent_name ~tool_access
              keeper_name));
      let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
      let token = Masc.Auth.ensure_internal_keeper_token base_path in
      let request = Yojson.Safe.to_string (`Assoc [
        ("jsonrpc", `String "2.0");
        ("id", `Int 120);
        ("method", `String "tools/call");
        ("params", `Assoc [
          ("name", `String "tool_execute");
          ( "arguments",
            `Assoc
              [
                ("_agent_name", `String keeper_agent_name);
                ("executable", `String "pwd");
                ("argv", `List []);
              ] );
        ]);
      ]) in
      let response =
        Mcp_eio.handle_request ~clock ~sw ~auth_token:token
          ~internal_keeper_runtime:true state request
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
      Alcotest.(check bool) "mentions retired tool_execute" true
        (contains_substring msg "Unknown tool: tool_execute");
      Alcotest.(check bool) "does not include did-you-mean suggestion" false
        (contains_substring msg "did you mean");
      Alcotest.(check bool) "mentions registry inconsistency" true
        (contains_substring msg "registry inconsistency"))

let test_internal_keeper_runtime_cleanup_preserves_primary_exception () =
  let module T = Masc.Mcp_server_eio_execute.For_testing in
  let cleanup_called = ref false in
  let cleanup ~during_exception () =
    T.cleanup_internal_keeper_runtime_resource ~during_exception
      ~label:"test sandbox" (fun () ->
        cleanup_called := true;
        failwith "cleanup failed")
  in
  let observed =
    try
      ignore
        (T.run_with_cleanup_preserving_primary ~cleanup (fun () ->
             failwith "tool failed"));
      None
    with
    | Failure message -> Some message
    | exn -> Some (Printexc.to_string exn)
  in
  Alcotest.(check (option string)) "primary tool exception surfaces"
    (Some "tool failed") observed;
  Alcotest.(check bool) "cleanup ran on exception path" true !cleanup_called

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
  let msg = error_message_exn response in
  Alcotest.(check bool)
    "invalid cursor error preserves contract label" true
    (contains_substring msg "Invalid params: cursor");
  Alcotest.(check bool)
    "invalid cursor error names received string" true
    (contains_substring msg "not-base64");
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
  let msg = error_message_exn response in
  Alcotest.(check bool)
    "invalid cursor error preserves contract label" true
    (contains_substring msg "Invalid params: cursor");
  Alcotest.(check bool)
    "invalid cursor error names received string" true
    (contains_substring msg "bad-cursor");
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
    (List.length prompts >= 1);
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
  Alcotest.(check int) "cursor trims first prompt" 0 (List.length prompts);
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
  ignore (Masc.Workspace.init (Mcp_server.workspace_config state) ~agent_name:(Some "fixture-root"));
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

let test_handle_request_status_json_reports_backlog_read_error () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw ->
  let base_path = temp_dir () in
  let state = Mcp_eio.create_state ~test_mode:true ~base_path () in
  let config = Mcp_server.workspace_config state in
  ignore (Masc.Workspace.init config ~agent_name:(Some "fixture-root"));
  let remove_if_exists path =
    if Sys.file_exists path then Sys.remove path
  in
  remove_if_exists (Masc.Workspace.backlog_path config);
  remove_if_exists (Masc.Workspace.backlog_recovery_path config);
  let request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 251);
          ("method", `String "resources/read");
          ("params", `Assoc [ ("uri", `String "masc://status.json") ]);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check string) "status.json mime type" "application/json"
    (resource_mime_type_exn response);
  let json = response |> resource_text_exn |> Yojson.Safe.from_string in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "backlog status" "read_error"
    (json |> member "backlog_status" |> to_string);
  Alcotest.(check int) "backlog error count" 1
    (json |> member "backlog_read_error_count" |> to_int);
  (match json |> member "backlog" with
   | `Null -> ()
   | other ->
       Alcotest.fail
         (Printf.sprintf
            "expected backlog=null on read error, got %s"
            (Yojson.Safe.to_string other)));
  (match json |> member "backlog_read_errors" |> to_list with
   | _ :: _ -> ()
   | [] -> Alcotest.fail "expected backlog_read_errors to explain the read failure");
  let tasks_request =
    Yojson.Safe.to_string
      (`Assoc
        [
          ("jsonrpc", `String "2.0");
          ("id", `Int 252);
          ("method", `String "resources/read");
          ("params", `Assoc [ ("uri", `String "masc://tasks.json") ]);
        ])
  in
  let tasks_response = Mcp_eio.handle_request ~clock ~sw state tasks_request in
  Alcotest.(check string) "tasks.json mime type" "application/json"
    (resource_mime_type_exn tasks_response);
  let tasks_json = tasks_response |> resource_text_exn |> Yojson.Safe.from_string in
  Alcotest.(check string) "tasks backlog status" "read_error"
    (tasks_json |> member "backlog_status" |> to_string);
  Alcotest.(check int) "tasks backlog error count" 1
    (tasks_json |> member "backlog_read_error_count" |> to_int);
  (match tasks_json |> member "tasks" with
   | `Null -> ()
   | other ->
       Alcotest.fail
         (Printf.sprintf
            "expected tasks=null on backlog read error, got %s"
            (Yojson.Safe.to_string other)));
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

let test_handle_request_dashboard_ping_requires_session () =
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
          ("id", `Int 242);
          ("method", `String "dashboard/ping");
          ("params", `Assoc []);
        ])
  in
  let response = Mcp_eio.handle_request ~clock ~sw state request in
  Alcotest.(check bool) "ping requires ws session" true
    (contains_substring
       (Yojson.Safe.to_string response)
       "dashboard/ping requires a WebSocket session");
  cleanup_dir base_path

let test_handle_request_dashboard_ping_reports_unknown_ws_session () =
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
          ("id", `Int 243);
          ("method", `String "dashboard/ping");
          ("params", `Assoc []);
        ])
  in
  let response =
    Mcp_eio.handle_request
      ~clock
      ~sw
      ~mcp_session_id:"missing-dashboard-ws-session"
      state
      request
  in
  Alcotest.(check bool) "unknown ws session reported" true
    (contains_substring
       (Yojson.Safe.to_string response)
       "WebSocket session not found");
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

let eio_tests = [
  "handle initialize", `Quick, test_handle_request_initialize;
  "handle initialize rejects unsupported protocol version", `Quick,
    test_handle_request_initialize_rejects_unsupported_protocol_version;
  "handle server/discover advertises 2026", `Quick,
    test_handle_request_server_discover_2026;
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
  "handle resources/read status.json reports backlog read error", `Quick,
    test_handle_request_status_json_reports_backlog_read_error;
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
  "handle tools/list with placeholder flag", `Quick, test_handle_request_tools_list_with_placeholder_flag;
  "handle tools/list include hidden metadata", `Quick,
    test_handle_request_tools_list_include_hidden_metadata;
  (* execution_session_turn hide test removed — team session cleanup *)
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
  "handle tools/call managed translation error records duration", `Quick,
    test_handle_request_tools_call_managed_translation_error_records_duration;
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
  "handle tools/list internal keeper runtime hides keeper internal tools", `Quick,
    test_handle_request_tools_list_internal_keeper_runtime_hides_keeper_internal_tools;
  "handle tools/call internal keeper runtime rejects retired execute", `Quick,
    test_handle_request_tools_call_internal_keeper_runtime_rejects_retired_execute;
  "internal keeper runtime cleanup preserves primary exception", `Quick,
    test_internal_keeper_runtime_cleanup_preserves_primary_exception;
  "handle invalid json", `Quick, test_handle_request_invalid_json;
  "handle method not found", `Quick, test_handle_request_method_not_found;
  (* TRPG tool tests removed — modules archived *)
  (* Governance status tool test removed *)
  (* execution_session_step direct call test removed — team session cleanup *)
  "explicit agent_name not overridden", `Quick, test_execute_tool_explicit_agent_name_not_overridden;
  "tool-domain agent_name does not reuse bound nickname", `Quick,
    test_execute_tool_domain_agent_name_does_not_reuse_joined_nickname;
  "generated agent_name uses token identity", `Quick,
    test_execute_tool_generated_agent_name_uses_token_identity;
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
  "legacy argument token ignored without http auth", `Quick,
    test_execute_tool_legacy_argument_token_ignored_without_http_auth;
  "without mcp session uses generated identity", `Quick,
    test_execute_tool_without_mcp_session_uses_generated_identity;
  (* Legacy governance convo workspace test removed *)
]

let () =
  Alcotest.run "Mcp_server_eio" [
    "state", state_tests;
    "protocol", protocol_tests;
    "response", response_tests;
    "eio", eio_tests;
  ]
