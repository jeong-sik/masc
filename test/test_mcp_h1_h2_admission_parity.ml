open Alcotest

module Transport = Masc_mcp.Server_mcp_transport_http
module Request_context = Masc_mcp.Server_mcp_request_context
module Headers = Masc_mcp.Server_mcp_transport_http_headers
module Negotiation = Mcp_transport_protocol.Http_negotiation

let source_file rel =
  let path = Filename.concat (Sys.getcwd ()) rel in
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

let request ?(headers = []) ?(meth = `POST) target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) meth target

let body method_ =
  Printf.sprintf {|{"jsonrpc":"2.0","id":1,"method":"%s","params":{}}|} method_

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
    | Negotiation.Legacy_accepted, Negotiation.Legacy_accepted
    | Negotiation.Rejected, Negotiation.Rejected ->
        true
    | _ -> false
  in
  check bool label true same

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
  let json_only_request =
    request ~headers:[ ("accept", "application/json") ] "/mcp"
  in
  (match
     Request_context.decide_post_body ~request:streamable_request
       ~context:(context ()) ~session_is_known:true (body "tools/call")
   with
  | Ok decision ->
      assert_accept_mode "streamable decision" Negotiation.Streamable
        decision.accept_mode;
      check (list (pair string string)) "no warning headers" []
        decision.accept_warn_headers
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
  | Error _ -> fail "unknown session should still permit initialize")

let test_shared_post_admission_matrix () =
  assert_result_ok "initialize may mint a fresh session"
    (Transport.validate_session_requirement ~session_was_provided:false
       initialize_body);
  assert_result_error "tools/call requires a session id"
    (Transport.validate_session_requirement ~session_was_provided:false
       (body "tools/call"));
  assert_result_ok "known session passes Q3"
    (Transport.validate_session_known ~session_was_provided:true ~is_known:true
       (body "tools/call"));
  assert_result_error "unknown session blocks tools/call"
    (Transport.validate_session_known ~session_was_provided:true ~is_known:false
       (body "tools/call"));
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
    (Headers.classify_mcp_accept_for_body streamable_request (body "tools/call"));
  assert_accept_mode "json-only Accept is rejected for requests" Negotiation.Rejected
    (Headers.classify_mcp_accept_for_body json_only_request (body "tools/call"));
  assert_accept_mode "json-only notifications remain legacy-compatible"
    Negotiation.Legacy_accepted
    (Headers.classify_mcp_accept_for_body json_only_request
       {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|})

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
    ];
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
        ] );
      ( "route-wiring",
        [
          test_case "H1/H2 POST route uses the same admission gates" `Quick
            test_h1_h2_post_route_wiring_parity;
          test_case "H1/H2 DELETE route uses the same admission gates" `Quick
            test_h1_h2_delete_route_wiring_parity;
        ] );
    ]
