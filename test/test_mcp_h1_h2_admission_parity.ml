open Alcotest

module Transport = Server_mcp_transport_http
module Request_context = Server_mcp_request_context
module Headers = Server_mcp_transport_http_headers
module Negotiation = Mcp_transport_protocol.Http_negotiation
module Mcp_store = Masc.Session.McpSessionStore
module Auth = Masc.Auth

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when Sys.file_exists (Filename.concat root "dune-project") -> root
  | _ -> Sys.getcwd ()

let resolve_path rel =
  if Filename.is_relative rel then Filename.concat (source_root ()) rel else rel

let source_file rel =
  let path = resolve_path rel in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let contains ~needle haystack =
  String.length needle = 0 || String_util.contains_substring haystack needle

let assert_contains label ~needle source =
  check bool label true (contains ~needle source)

let assert_order label ~before ~after source =
  let before_idx = Str.search_forward (Str.regexp_string before) source 0 in
  let after_idx = Str.search_forward (Str.regexp_string after) source 0 in
  check bool label true (before_idx < after_idx)

let request ?(headers = []) ?(meth = `POST) target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) meth target

let body method_ =
  Printf.sprintf {|{"jsonrpc":"2.0","id":1,"method":"%s","params":{}}|} method_

let stateless_body ?(method_ = "tools/list") ?name () =
  let params_fields =
    [ ("_meta",
       `Assoc
         [
           ( Mcp_transport_protocol.protocol_version_meta_key,
             `String "2026-07-28" );
           ( "io.modelcontextprotocol/clientInfo",
             `Assoc
               [ ("name", `String "parity-test"); ("version", `String "0.1") ]
           );
           ("io.modelcontextprotocol/clientCapabilities", `Assoc []);
         ] )
    ]
    @
    match name with
    | None -> []
    | Some value -> [ ("name", `String value) ]
  in
  `Assoc
    [
      ("jsonrpc", `String "2.0");
      ("id", `Int 1);
      ("method", `String method_);
      ("params", `Assoc params_fields);
    ]
  |> Yojson.Safe.to_string

let initialize_body =
  {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"parity-test","version":"0.1"}}}|}

let assert_result_ok label = function
  | Ok () -> ()
  | Error msg -> failf "%s expected Ok, got Error %S" label msg

let assert_result_error label = function
  | Ok () -> failf "%s expected Error, got Ok" label
  | Error msg -> check bool (label ^ " message is not empty") true (String.length msg > 0)

let assert_accept_mode label expected actual =
  let same =
    match (expected, actual) with
    | Negotiation.Streamable, Negotiation.Streamable
    | Negotiation.Rejected, Negotiation.Rejected ->
        true
    | _ -> false
  in
  check bool label true same

let metric_value name labels =
  Masc.Otel_metric_store.get_metric_value name ~labels ()
  |> Option.value ~default:0.0

let context ?(session_id = "ctx-session") ?(session_was_provided = true) () =
  Request_context.make
    ~session_id_opt:(if session_was_provided then Some session_id else None)
    ~generated_session_id:session_id ~auth_token:None
    ~protocol_version:"2025-11-25" ~origin:"*" ~base_path:"/tmp/masc-test"

let test_request_context_make_records_session_source () =
  let supplied =
    Request_context.make ~session_id_opt:(Some "supplied-session")
      ~generated_session_id:"generated-session" ~auth_token:(Some "token")
      ~protocol_version:"2025-11-25" ~origin:"https://example.test"
      ~base_path:"/tmp/base"
  in
  check string "supplied session wins" "supplied-session" supplied.session_id;
  check bool "supplied flag" true supplied.session_was_provided;
  check (option string) "auth token" (Some "token") supplied.auth_token;
  check string "protocol version" "2025-11-25" supplied.protocol_version;
  check string "origin" "https://example.test" supplied.origin;
  check string "base path" "/tmp/base" supplied.base_path;
  let generated =
    Request_context.make ~session_id_opt:None
      ~generated_session_id:"generated-session" ~auth_token:None
      ~protocol_version:"2025-11-25" ~origin:"*" ~base_path:"/tmp/base"
  in
  check string "generated fallback" "generated-session" generated.session_id;
  check bool "generated flag" false generated.session_was_provided

let test_request_context_decides_post_body () =
  let streamable_request =
    request ~headers:[ ("accept", "application/json, text/event-stream") ] "/mcp"
  in
  let stateless_request =
    request
      ~headers:
        [
          ("accept", "application/json, text/event-stream");
          ("mcp-protocol-version", "2026-07-28");
          ("mcp-method", "tools/list");
        ]
      "/mcp"
  in
  let stateless_bad_method_request =
    request
      ~headers:
        [
          ("accept", "application/json, text/event-stream");
          ("mcp-protocol-version", "2026-07-28");
          ("mcp-method", "tools/call");
        ]
      "/mcp"
  in
  let json_only_request =
    request ~headers:[ ("accept", "application/json") ] "/mcp"
  in
  (match
     Request_context.decide_post_body ~request:streamable_request
       ~context:(context ()) ~session_is_known:true (body "tools/call")
   with
  | Ok decision ->
      assert_accept_mode "streamable decision" Negotiation.Streamable
        decision.accept_mode
  | Error _ -> fail "streamable known session should pass");
  (match
     Request_context.decide_post_body ~request:streamable_request
       ~context:(context ~session_was_provided:false ()) ~session_is_known:false
       (body "tools/call")
   with
  | Error (Request_context.Session_required msg) ->
      check bool "session required message" true (String.length msg > 0)
  | Ok _ -> fail "missing session should reject tools/call"
  | Error _ -> fail "missing session should use Session_required");
  (match
     Request_context.decide_post_body ~request:streamable_request
       ~context:(context ()) ~session_is_known:false (body "tools/call")
   with
  | Error (Request_context.Unknown_session msg) ->
      check bool "unknown session message" true (String.length msg > 0)
  | Ok _ -> fail "unknown session should reject tools/call"
  | Error _ -> fail "unknown session should use Unknown_session");
  (match
     Request_context.decide_post_body ~request:json_only_request
       ~context:(context ()) ~session_is_known:true (body "tools/call")
   with
  | Error (Request_context.Invalid_accept msg) ->
      check string "invalid accept message" Request_context.invalid_accept_message
        msg
  | Ok _ -> fail "json-only request should reject tools/call"
  | Error _ -> fail "json-only request should use Invalid_accept");
  (match
     Request_context.decide_post_body ~request:streamable_request
       ~context:(context ()) ~session_is_known:false initialize_body
   with
  | Ok _ -> ()
  | Error _ -> fail "unknown session should still permit initialize");
  (match
     Request_context.decide_post_body ~request:stateless_request
       ~context:(context ~session_was_provided:false ()) ~session_is_known:false
       (stateless_body ())
   with
  | Ok decision ->
      assert_accept_mode "stateless decision" Negotiation.Streamable
        decision.accept_mode
  | Error _ -> fail "stateless 2026 request should not require a session");
  (match
     Request_context.decide_post_body ~request:stateless_bad_method_request
       ~context:(context ~session_was_provided:false ()) ~session_is_known:false
       (stateless_body ())
   with
  | Error (Request_context.Header_mismatch msg) ->
      check bool "header mismatch mentions Mcp-Method" true
        (contains ~needle:"Mcp-Method" msg)
  | Ok _ -> fail "mismatched stateless headers should reject"
  | Error _ -> fail "mismatched stateless headers should use Header_mismatch")

let test_shared_post_admission_matrix () =
  assert_result_ok "initialize may mint a fresh session"
    (Transport.validate_session_requirement ~session_was_provided:false
       initialize_body);
  assert_result_error "tools/call requires a session id"
    (Transport.validate_session_requirement ~session_was_provided:false
       (body "tools/call"));
  assert_result_ok "2026 stateless request does not require a session id"
    (Transport.validate_session_requirement ~session_was_provided:false
       (stateless_body ()));
  assert_result_ok "known session passes Q3"
    (Transport.validate_session_known ~session_was_provided:true ~is_known:true
       (body "tools/call"));
  assert_result_error "unknown session blocks tools/call"
    (Transport.validate_session_known ~session_was_provided:true ~is_known:false
       (body "tools/call"));
  assert_result_ok "unknown supplied session is ignored for 2026 stateless"
    (Transport.validate_session_known ~session_was_provided:true ~is_known:false
       (stateless_body ()));
  assert_result_ok "unknown session still permits initialize"
    (Transport.validate_session_known ~session_was_provided:true ~is_known:false
       initialize_body);
  let streamable_request =
    request ~headers:[ ("accept", "application/json, text/event-stream") ] "/mcp"
  in
  let json_only_request =
    request ~headers:[ ("accept", "application/json") ] "/mcp"
  in
  assert_accept_mode "streamable Accept remains admitted" Negotiation.Streamable
    (Headers.classify_mcp_accept streamable_request);
  assert_accept_mode "json-only Accept is rejected for requests" Negotiation.Rejected
    (Headers.classify_mcp_accept json_only_request);
  assert_accept_mode "json-only notifications are rejected"
    Negotiation.Rejected
    (Headers.classify_mcp_accept json_only_request)

let test_shared_protocol_and_delete_matrix () =
  let session_id = "h1-h2-parity-protocol-session" in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      Transport.remember_protocol_version session_id "2025-11-25";
      assert_result_ok "missing protocol header preserves continuity"
        (Transport.validate_protocol_version_continuity ~session_id
           (request "/mcp"));
      assert_result_error "mismatched protocol header is rejected"
        (Transport.validate_protocol_version_continuity ~session_id
           (request
              ~headers:[ ("mcp-protocol-version", "2025-03-26") ]
              "/mcp")));
  let delete_session = "h1-h2-parity-delete-session" in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session delete_session)
    (fun () ->
      Transport.remember_mcp_profile delete_session Transport.Full;
      assert_result_ok "matching DELETE profile passes"
        (Transport.validate_mcp_session_delete_profile ~profile:Transport.Full
           delete_session);
      assert_result_error "mismatched DELETE profile is rejected"
        (Transport.validate_mcp_session_delete_profile
           ~profile:Transport.Managed_agent delete_session));
  check (option string) "DELETE without session has no admission id" None
    (Transport.get_session_id_any (request ~meth:`DELETE "/mcp"))

let test_sse_backing_session_bridge_requires_known_transport_session () =
  let transport_session_id = "h1-h2-parity-sse-transport-session" in
  let sse_session_id = "presence:" ^ transport_session_id in
  let unknown_transport_session_id =
    "h1-h2-parity-sse-unknown-transport-session"
  in
  let unknown_sse_session_id = "presence:" ^ unknown_transport_session_id in
  let cleanup () =
    Transport.forget_mcp_session transport_session_id;
    Transport.forget_mcp_session unknown_transport_session_id;
    ignore (Mcp_store.remove sse_session_id);
    ignore (Mcp_store.remove unknown_sse_session_id)
  in
  Fun.protect ~finally:cleanup (fun () ->
      cleanup ();
      Transport.remember_protocol_version transport_session_id "2025-11-25";
      Transport.ensure_sse_backing_session_for_known_transport_session
        ~transport_session_id ~sse_session_id;
      check bool "known transport session creates SSE backing session" true
        (Option.is_some (Mcp_store.peek sse_session_id));
      Transport.ensure_sse_backing_session_for_known_transport_session
        ~transport_session_id:unknown_transport_session_id
        ~sse_session_id:unknown_sse_session_id;
      check bool "unknown transport session does not mint SSE backing session"
        true
        (Option.is_none (Mcp_store.peek unknown_sse_session_id)))

let test_records_mcp_server_session_duration_metric () =
  let session_id = "h1-h2-parity-session-duration" in
  let transport_context =
    Otel_dispatch_hook.http_transport_context ~protocol_version:"1.1"
  in
  let labels =
    [
      (Otel_genai.Mcp_attr_key.mcp_protocol_version, "2025-11-25");
      (Otel_genai.Mcp_attr_key.network_protocol_name, "http");
      (Otel_genai.Mcp_attr_key.network_protocol_version, "1.1");
      (Otel_genai.Mcp_attr_key.network_transport, "tcp");
    ]
  in
  let count_metric =
    Otel_genai.Mcp_metric_name.server_session_duration ^ "_count"
  in
  let before_count = metric_value count_metric labels in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      Transport.remember_protocol_version
        ~otel_transport_context:transport_context
        session_id
        "2025-11-25";
      Transport.forget_mcp_session session_id);
  let after_count = metric_value count_metric labels in
  check (float 0.0001) "server session duration count increments"
    (before_count +. 1.0)
    after_count

let test_uninitialized_profile_does_not_start_session_duration_metric () =
  let session_id = "h1-h2-parity-profile-only-session" in
  let transport_context =
    Otel_dispatch_hook.http_transport_context ~protocol_version:"1.1"
  in
  let count_metric =
    Otel_genai.Mcp_metric_name.server_session_duration ^ "_count"
  in
  let before_count = metric_value count_metric [] in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      Transport.remember_mcp_profile
        ~otel_transport_context:transport_context
        session_id
        Transport.Full;
      Transport.forget_mcp_session session_id);
  let after_count = metric_value count_metric [] in
  check (float 0.0001)
    "profile-only uninitialized session does not record duration"
    before_count
    after_count

let test_failed_initialize_does_not_start_session_duration_metric () =
  let session_id = "h1-h2-parity-failed-initialize-session" in
  let transport_context =
    Otel_dispatch_hook.http_transport_context ~protocol_version:"1.1"
  in
  let request_body =
    {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{}}}|}
  in
  let response_json =
    Mcp_transport_protocol.make_error
      ~id:(`Int 1)
      (Masc.Mcp_error_code.to_wire_code Masc.Mcp_error_code.Invalid_params)
      "Missing clientInfo"
  in
  let count_metric =
    Otel_genai.Mcp_metric_name.server_session_duration ^ "_count"
  in
  let before_count = metric_value count_metric [] in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      Transport.remember_protocol_version_if_initialize_succeeded
        ~otel_transport_context:transport_context
        session_id
        ~request_body
        ~response_json;
      check bool "failed initialize leaves session unknown" false
        (Transport.is_known_session session_id);
      Transport.forget_mcp_session session_id);
  let after_count = metric_value count_metric [] in
  check (float 0.0001)
    "failed initialize does not record session duration"
    before_count
    after_count

let test_h1_h2_post_route_wiring_parity () =
  let h1 = source_file "lib/server/server_mcp_transport_http.ml" in
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  List.iter
    (fun (label, needle) ->
      assert_contains ("H1 " ^ label) ~needle h1;
      assert_contains ("H2 " ^ label) ~needle h2)
    [
      ("uses shared POST request context", "Server_mcp_request_context.decide_post_body");
      ("injects canonical HTTP actor", "body_with_canonical_http_actor");
      ("forwards internal keeper runtime", "is_verified_internal_keeper_request");
      ( "records initialize protocol only after success",
        "remember_protocol_version_if_initialize_succeeded" );
    ];
  assert_order "H1 refreshes MCP profile after auth gate"
    ~before:"match auth_result with"
    ~after:"remember_mcp_profile ~otel_transport_context session_id profile"
    h1;
  assert_order "H2 refreshes MCP profile after auth gate"
    ~before:"match auth_result with"
    ~after:"remember_mcp_profile"
    h2;
  assert_contains "H1 unknown supplied session returns not found"
    ~needle:"Httpun.Response.create ~headers `Not_found" h1;
  assert_contains "H2 unknown supplied session returns not found"
    ~needle:"~status:`Not_found" h2

let test_h1_h2_delete_route_wiring_parity () =
  let h1 = source_file "lib/server/server_mcp_transport_http.ml" in
  let h1_routes = source_file "lib/server/server_routes_http_routes_frontend.ml" in
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  assert_contains "H1 exposes DELETE /mcp route"
    ~needle:{|Http.Router.add ~path:"/mcp" ~methods:[`DELETE]|}
    h1_routes;
  assert_contains "H1 exposes DELETE /mcp/managed route"
    ~needle:{|Http.Router.add ~path:"/mcp/managed" ~methods:[`DELETE]|}
    h1_routes;
  assert_contains "H2 exposes DELETE /mcp route"
    ~needle:{|`DELETE, "/mcp" | `DELETE, "/mcp/managed" ->|}
    h2;
  List.iter
    (fun (label, needle) ->
      assert_contains ("H1 DELETE " ^ label) ~needle h1;
      assert_contains ("H2 DELETE " ^ label) ~needle h2)
    [
      ("verifies MCP auth", "verify_mcp_auth ~base_path");
      ("checks session profile", "validate_mcp_session_delete_profile");
      ("checks protocol continuity", "validate_protocol_version_continuity");
      ("forgets session after termination", "forget_mcp_session session_id");
    ]

(* /ws upgrade admission — a bearer credential with CanReadState is the
   boundary. Same-origin never substitutes for authentication, and Origin
   metadata does not override an explicitly authenticated non-browser/proxy
   client. *)
let rec remove_path path =
  if Sys.file_exists path
  then if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun name -> remove_path (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_ws_auth_dir f =
  let path = Filename.temp_file "ws-upgrade-auth" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_path path) (fun () ->
    Auth.save_auth_config path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    f path)

let worker_token base_path =
  match Auth.create_token base_path ~agent_name:"ws-test-agent" ~role:Masc_domain.Worker with
  | Ok (token, _credential) -> token
  | Error err -> fail (Masc_domain.masc_error_to_string err)

let ws_upgrade_request ?token headers =
  let target =
    match token with
    | None -> "/ws"
    | Some token -> "/ws?token=" ^ Uri.pct_encode token
  in
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET target

let ws_gate ?token ~base_path headers =
  Server_routes_http_routes_frontend.websocket_upgrade_authorized
    ~base_path
    (ws_upgrade_request ?token headers)

let test_ws_upgrade_denied_without_token () =
  with_ws_auth_dir @@ fun base_path ->
  match
    ws_gate
      ~base_path
      [ ("host", "127.0.0.1:8935"); ("origin", "http://127.0.0.1:8935") ]
  with
  | Ok _ -> fail "expected deny: same-origin request has no bearer token"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf
      "expected Auth error, got %s"
      (Masc_domain.masc_error_to_string other)

let test_ws_upgrade_allows_token_bound_same_origin () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  match
    ws_gate
      ~token
      ~base_path
      [ ("host", "127.0.0.1:8935"); ("origin", "http://127.0.0.1:8935") ]
  with
  | Ok admission -> check string "retained bearer" token admission.auth_token
  | Error err ->
    failf
      "expected token-bound same-origin upgrade to pass, got %s"
      (Masc_domain.masc_error_to_string err)

let test_ws_upgrade_allows_token_bound_cross_origin () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  match
    ws_gate
      ~token
      ~base_path
      [ ("host", "127.0.0.1:8935"); ("origin", "http://evil.example:8935") ]
  with
  | Ok admission -> check string "retained bearer" token admission.auth_token
  | Error err ->
    failf
      "expected token-bound cross-origin upgrade to pass, got %s"
      (Masc_domain.masc_error_to_string err)

let test_ws_upgrade_allows_bearer_header_for_non_browser_client () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  let request =
    ws_upgrade_request
      [
        ("host", "127.0.0.1:8935");
        ("origin", "http://evil.example:8935");
        ("authorization", "Bearer " ^ token);
      ]
  in
  match
    Server_routes_http_routes_frontend.websocket_upgrade_authorized
      ~base_path
      request
  with
  | Ok admission -> check string "retained bearer" token admission.auth_token
  | Error err ->
    failf
      "expected bearer-authenticated non-browser upgrade to pass, got %s"
      (Masc_domain.masc_error_to_string err)

let test_ide_lsp_websocket_denies_tokenless_same_origin () =
  with_ws_auth_dir @@ fun base_path ->
  let request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [
             ("host", "127.0.0.1:8935");
             ("origin", "http://127.0.0.1:8935");
           ])
      `GET
      "/api/v1/ide/lsp"
  in
  match
    Server_auth.authorize_websocket_request
      ~base_path
      ~permission:Masc_domain.CanReadState
      request
  with
  | Ok _ -> fail "expected IDE LSP same-origin request without token to be denied"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf
      "expected Auth error, got %s"
      (Masc_domain.masc_error_to_string other)

let test_ide_lsp_websocket_allows_token_bound_same_origin () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  let request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [
             ("host", "127.0.0.1:8935");
             ("origin", "http://127.0.0.1:8935");
           ])
      `GET
      ("/api/v1/ide/lsp?token=" ^ Uri.pct_encode token)
  in
  match
    Server_auth.authorize_websocket_request
      ~base_path
      ~permission:Masc_domain.CanReadState
      request
  with
  | Ok admission ->
    check string "credential owner" "ws-test-agent" admission.identity.agent_name;
    check string "retained bearer" token admission.auth_token
  | Error err ->
    failf
      "expected token-bound IDE LSP upgrade to pass, got %s"
      (Masc_domain.masc_error_to_string err)

let test_ws_dispatch_carries_admitted_bearer () =
  let body = {|{"jsonrpc":"2.0","id":1,"method":"tools/list"}|} in
  let observed = ref None in
  Server_mcp_transport_ws.set_inbound_message_handler
    (fun ~auth_token session_id message ->
      observed := Some (auth_token, session_id, message));
  Server_mcp_transport_ws.dispatch_inbound_message
    ~auth_token:"admitted-token"
    "ws-auth-session"
    body;
  check
    (option (triple (option string) string string))
    "per-connection bearer reaches MCP dispatcher"
    (Some (Some "admitted-token", "ws-auth-session", body))
    !observed

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "mcp_h1_h2_admission_parity"
    [
      ( "shared-admission-matrix",
        [
          test_case "request context records pre-body state" `Quick
            test_request_context_make_records_session_source;
          test_case "request context decides POST body admission" `Quick
            test_request_context_decides_post_body;
          test_case "POST shared predicate matrix" `Quick
            test_shared_post_admission_matrix;
          test_case "protocol and DELETE predicate matrix" `Quick
            test_shared_protocol_and_delete_matrix;
          test_case "SSE backing session bridge requires known transport session"
            `Quick
            test_sse_backing_session_bridge_requires_known_transport_session;
          test_case "server session duration metric" `Quick
            test_records_mcp_server_session_duration_metric;
          test_case "profile-only session does not start duration metric" `Quick
            test_uninitialized_profile_does_not_start_session_duration_metric;
          test_case "failed initialize does not start duration metric" `Quick
            test_failed_initialize_does_not_start_session_duration_metric;
        ] );
      ( "route-wiring",
        [
          test_case "H1/H2 POST route uses the same admission gates" `Quick
            test_h1_h2_post_route_wiring_parity;
          test_case "H1/H2 DELETE route uses the same admission gates" `Quick
            test_h1_h2_delete_route_wiring_parity;
        ] );
      ( "ws-upgrade-admission",
        [
          test_case "denies same-origin upgrade without token" `Quick
            test_ws_upgrade_denied_without_token;
          test_case "allows token-bound same-origin upgrade" `Quick
            test_ws_upgrade_allows_token_bound_same_origin;
          test_case "allows token-bound cross-origin upgrade" `Quick
            test_ws_upgrade_allows_token_bound_cross_origin;
          test_case "allows bearer header for non-browser clients" `Quick
            test_ws_upgrade_allows_bearer_header_for_non_browser_client;
          test_case "carries admitted bearer into MCP dispatcher" `Quick
            test_ws_dispatch_carries_admitted_bearer;
          test_case "IDE LSP denies tokenless same-origin upgrade" `Quick
            test_ide_lsp_websocket_denies_tokenless_same_origin;
          test_case "IDE LSP allows token-bound same-origin upgrade" `Quick
            test_ide_lsp_websocket_allows_token_bound_same_origin;
        ] );
    ]
