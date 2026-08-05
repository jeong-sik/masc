open Alcotest

module Transport = Server_mcp_transport_http
module Request_context = Server_mcp_request_context
module Headers = Server_mcp_transport_http_headers
module Negotiation = Mcp_transport_protocol.Http_negotiation
module Auth = Masc.Auth

let request_trust_policy =
  match
    Server_request_authority.make_trust_policy
      ~bind_host:"127.0.0.1"
      ~bind_port:8935
      ~explicit_base_url:None
  with
  | Ok policy -> policy
  | Error error ->
    fail (Server_request_authority.trust_policy_error_to_string error)
;;

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

let assert_not_contains label ~needle source =
  check bool label false (contains ~needle source)

let assert_order label ~before ~after source =
  let before_idx = Str.search_forward (Str.regexp_string before) source 0 in
  let after_idx = Str.search_forward (Str.regexp_string after) source 0 in
  check bool label true (before_idx < after_idx)

let request ?(headers = []) ?(meth = `POST) target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) meth target

let body method_ =
  Printf.sprintf {|{"jsonrpc":"2.0","id":1,"method":"%s","params":{}}|} method_

let stateless_body ?(method_ = "tools/list") ?name
    ?(protocol_version = "2026-07-28") () =
  let params_fields =
    [ ("_meta",
       `Assoc
         [
           ( Mcp_transport_protocol.protocol_version_meta_key,
             `String protocol_version );
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

let assert_accept_mode label expected actual =
  let same =
    match (expected, actual) with
    | Negotiation.Streamable, Negotiation.Streamable
    | Negotiation.Rejected, Negotiation.Rejected ->
        true
    | _ -> false
  in
  check bool label true same

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
    request
      ~headers:
        [ ("accept", "application/json")
        ; ("mcp-protocol-version", "2026-07-28")
        ; ("mcp-method", "tools/list")
        ]
      "/mcp"
  in
  (match
     Request_context.decide_post_body ~request:streamable_request
       (body "tools/call")
   with
  | Error (Request_context.Header_mismatch _) -> ()
  | Ok _ -> fail "request without current headers must reject"
  | Error _ -> fail "missing current headers should use Header_mismatch");
  (match
     Request_context.decide_post_body ~request:streamable_request
       (body "tools/call")
   with
  | Error (Request_context.Header_mismatch _) -> ()
  | Ok _ -> fail "legacy sessionless request must reject"
  | Error _ -> fail "legacy request should use Header_mismatch");
  (match
     Request_context.decide_post_body ~request:streamable_request
       (body "tools/call")
   with
  | Error (Request_context.Header_mismatch _) -> ()
  | Ok _ -> fail "legacy supplied-session request must reject"
  | Error _ -> fail "legacy supplied-session request should use Header_mismatch");
  (match
     Request_context.decide_post_body ~request:json_only_request
       (stateless_body ())
   with
  | Error (Request_context.Invalid_accept msg) ->
      check string "invalid accept message" Request_context.invalid_accept_message
        msg
  | Ok _ -> fail "json-only request should reject tools/call"
  | Error _ -> fail "json-only request should use Invalid_accept");
  (match
     Request_context.decide_post_body ~request:stateless_request
       (stateless_body ())
   with
  | Ok decision ->
      assert_accept_mode "stateless decision" Negotiation.Streamable
        decision.accept_mode
  | Error _ -> fail "stateless 2026 request should not require a session");
  (match
     Request_context.decide_post_body ~request:stateless_bad_method_request
       (stateless_body ())
   with
  | Error (Request_context.Header_mismatch msg) ->
      check bool "header mismatch mentions Mcp-Method" true
        (contains ~needle:"Mcp-Method" msg)
  | Ok _ -> fail "mismatched stateless headers should reject"
  | Error _ -> fail "mismatched stateless headers should use Header_mismatch");
  let unsupported_request =
    request
      ~headers:
        [ ("accept", "application/json, text/event-stream")
        ; ("mcp-protocol-version", "unsupported-version")
        ; ("mcp-method", "tools/list")
        ]
      "/mcp"
  in
  (match
     Request_context.decide_post_body ~request:unsupported_request
       (stateless_body ~protocol_version:"unsupported-version" ())
   with
  | Error (Request_context.Unsupported_protocol_version requested) ->
      check string "reports rejected version" "unsupported-version" requested
  | Ok _ -> fail "previous final version must reject"
  | Error _ -> fail "unsupported version should use its typed rejection");
  let method_not_found =
    `Assoc
      [ ("jsonrpc", `String "2.0")
      ; ("id", `Int 1)
      ; ( "error"
        , `Assoc
            [ ("code", `Int (-32601)); ("message", `String "Method not found") ] )
      ]
  in
  check bool "method-not-found is an HTTP transport error" true
    (Headers.is_http_error_response method_not_found);
  check bool "method-not-found maps to HTTP 404" true
    (Headers.is_method_not_found_response method_not_found)

let test_transport_error_id_is_lossless () =
  let lexeme = "92233720368547758081234567890" in
  let body =
    Printf.sprintf
      {|{"jsonrpc":"2.0","id":%s,"method":"tools/list","params":{}}|}
      lexeme
  in
  check string "large integer id" lexeme
    (Headers.jsonrpc_id_or_null body |> Yojson.Safe.to_string)

let test_malformed_json_reaches_jsonrpc_parser () =
  let malformed_request =
    request
      ~headers:
        [ ("accept", "application/json, text/event-stream")
        ; ("mcp-protocol-version", "2026-07-28")
        ; ("mcp-method", "tools/list")
        ]
      "/mcp"
  in
  match Headers.validate_2026_request_headers malformed_request "{" with
  | Ok () -> ()
  | Error error -> fail ("transport intercepted malformed JSON: " ^ error)

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
  List.iter
    (fun (label, code) ->
      assert_contains ("H1 emits " ^ label) ~needle:code h1;
      assert_contains ("H2 emits " ^ label) ~needle:code h2)
    [ ("HeaderMismatch -32020", "-32020")
    ; ("UnsupportedProtocolVersion -32022", "-32022")
    ]

let test_current_only_route_wiring () =
  let h1 = source_file "lib/server/server_mcp_transport_http.ml" in
  let h1_routes = source_file "lib/server/server_routes_http_routes_frontend.ml" in
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  assert_not_contains "H1 removes DELETE /mcp route"
    ~needle:{|Http.Router.add ~path:"/mcp" ~methods:[`DELETE]|}
    h1_routes;
  assert_not_contains "H1 removes DELETE /mcp/managed route"
    ~needle:{|Http.Router.add ~path:"/mcp/managed" ~methods:[`DELETE]|}
    h1_routes;
  assert_not_contains "H2 removes DELETE /mcp route"
    ~needle:{|`DELETE, "/mcp" | `DELETE, "/mcp/managed" ->|}
    h2;
  assert_contains "H1 dashboard events moved outside MCP"
    ~needle:{|Http.Router.get "/events" handle_get_events|} h1_routes;
  assert_not_contains "H1 removes GET /mcp"
    ~needle:{|Http.Router.get "/mcp"|} h1_routes;
  ignore h1

let test_h2_oauth_route_and_authority_lifetime () =
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  List.iter
    (fun path ->
      assert_contains
        ("H2 exposes OAuth route " ^ path)
        ~needle:(Printf.sprintf "%S" path)
        h2)
    [ "/.well-known/oauth-protected-resource"
    ; "/.well-known/oauth-authorization-server"
    ; "/oauth/authorize"
    ; "/oauth/register"
    ; "/oauth/token"
    ];
  assert_contains
    "H2 derives the OAuth resource from the lexically admitted authority"
    ~needle:"Server_oauth_metadata.resource request_authority"
    h2;
  assert_not_contains
    "H2 callbacks do not re-read expired fiber-local authority"
    ~needle:"Server_request_authority.current_exn ()"
    h2;
  assert_not_contains
    "H2 does not call the HTTP/1 OAuth facade"
    ~needle:"Server_oauth_http"
    h2

(* /ws upgrade admission — token-or-same-origin gate parity with the /mcp
   POST chain.  A base_path with no auth config resolves to
   [default_auth_config], which is strict (enabled + require_token), so the
   token leg deterministically fails without a bearer token and the decision
   falls to the same-origin leg.  If the strict default ever flips, these
   deny cases must fail loudly — that is a security posture change. *)
let ws_absent_base_path () =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "ws-upgrade-auth-absent-%d" (Unix.getpid ()))

let ws_upgrade_request headers =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET "/ws"

let ws_gate_on ~base_path headers =
  let request = ws_upgrade_request headers in
  let request_authority =
    match
      Server_request_authority.classify_http1_request
        ~trust_policy:request_trust_policy
        request
    with
    | Server_request_authority.Single authority -> authority
    | ( Server_request_authority.Missing
      | Server_request_authority.Multiple
      | Server_request_authority.Malformed
      | Server_request_authority.Untrusted ) ->
      fail "expected valid authority"
  in
  Server_routes_http_routes_frontend.websocket_upgrade_authorized
    ~base_path
    ~request_authority
    request

let ws_gate headers = ws_gate_on ~base_path:(ws_absent_base_path ()) headers

let test_ws_upgrade_denied_without_token_or_origin () =
  match ws_gate [ ("host", "127.0.0.1:8935") ] with
  | Ok () -> fail "expected deny: no bearer token and no Origin header"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf "expected Auth error, got %s"
      (Masc_domain.masc_error_to_string other)

let test_ws_upgrade_allows_same_origin () =
  match
    ws_gate
      [ ("host", "127.0.0.1:8935"); ("origin", "http://127.0.0.1:8935") ]
  with
  | Ok () -> ()
  | Error err ->
    failf "expected same-origin upgrade to pass, got %s"
      (Masc_domain.masc_error_to_string err)

let test_ws_upgrade_denies_cross_origin () =
  match
    ws_gate
      [ ("host", "127.0.0.1:8935"); ("origin", "http://evil.example:8935") ]
  with
  | Ok () -> fail "expected deny: cross-origin upgrade without token"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf "expected Auth error, got %s"
      (Masc_domain.masc_error_to_string other)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path

let with_temp_auth_workspace f =
  let path = Filename.temp_file "masc-ws-upgrade-auth" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () ->
    Auth.save_auth_config path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    f path)

let test_ws_upgrade_allows_authenticated_cross_origin () =
  with_temp_auth_workspace (fun base_path ->
    let token =
      match
        Auth.create_token base_path ~agent_name:"ws-auth-test"
          ~role:Masc_domain.Worker
      with
      | Ok (raw_token, _) -> raw_token
      | Error err ->
        failf "expected test token creation to pass, got %s"
          (Masc_domain.masc_error_to_string err)
    in
    match
      ws_gate_on ~base_path
        [ ("host", "127.0.0.1:8935");
          ("origin", "http://evil.example:8935");
          ("authorization", "Bearer " ^ token) ]
    with
    | Ok () -> ()
    | Error err ->
      failf "expected authenticated cross-origin upgrade to pass, got %s"
        (Masc_domain.masc_error_to_string err))

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "mcp_h1_h2_admission_parity"
    [
      ( "shared-admission-matrix",
        [
          test_case "request context decides POST body admission" `Quick
            test_request_context_decides_post_body;
          test_case "transport errors preserve large integer ids" `Quick
            test_transport_error_id_is_lossless;
          test_case "malformed JSON reaches JSON-RPC parser" `Quick
            test_malformed_json_reaches_jsonrpc_parser;
        ] );
      ( "route-wiring",
        [
          test_case "H1/H2 POST route uses the same admission gates" `Quick
            test_h1_h2_post_route_wiring_parity;
          test_case "H1/H2 expose only current MCP routes" `Quick
            test_current_only_route_wiring;
          test_case "H2 OAuth routes preserve admitted authority" `Quick
            test_h2_oauth_route_and_authority_lifetime;
        ] );
      ( "ws-upgrade-admission",
        [
          test_case "denies upgrade without token or Origin" `Quick
            test_ws_upgrade_denied_without_token_or_origin;
          test_case "allows same-origin upgrade" `Quick
            test_ws_upgrade_allows_same_origin;
          test_case "denies cross-origin upgrade without token" `Quick
            test_ws_upgrade_denies_cross_origin;
          test_case "allows authenticated cross-origin upgrade" `Quick
            test_ws_upgrade_allows_authenticated_cross_origin;
        ] );
    ]
