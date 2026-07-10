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

let assert_not_contains label ~needle source =
  check bool label false (contains ~needle source)

let assert_order label ~before ~after source =
  let before_idx = Str.search_forward (Str.regexp_string before) source 0 in
  let after_idx = Str.search_forward (Str.regexp_string after) source 0 in
  check bool label true (before_idx < after_idx)

let assert_near_after label ~anchor ~needle ~within source =
  let anchor_idx = Str.search_forward (Str.regexp_string anchor) source 0 in
  let needle_idx =
    Str.search_forward (Str.regexp_string needle)
      source (anchor_idx + String.length anchor)
  in
  check bool label true (needle_idx - anchor_idx <= within)

let source_between ~start_anchor ~end_anchor source =
  let start_idx =
    Str.search_forward (Str.regexp_string start_anchor) source 0
  in
  let end_idx =
    Str.search_forward (Str.regexp_string end_anchor)
      source (start_idx + String.length start_anchor)
  in
  String.sub source start_idx (end_idx - start_idx)

let request ?(headers = []) ?(meth = `POST) target =
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) meth target

let test_origin_admission_is_exact_across_h1_h2 () =
  let h1_same_origin =
    request
      ~headers:
        [ "host", "127.0.0.1:8935"
        ; "origin", "http://127.0.0.1:8935"
        ]
      "/mcp"
  in
  let h1_prefix_attack =
    request
      ~headers:
        [ "host", "127.0.0.1:8935"
        ; "origin", "http://127.0.0.1.evil.test:8935"
        ]
      "/mcp"
  in
  check bool "H1 exact same-origin admitted" true
    (Server_routes_http.validate_origin h1_same_origin);
  check bool "H1 origin-prefix attacker rejected" false
    (Server_routes_http.validate_origin h1_prefix_attack);
  check bool "non-browser request without Origin admitted" true
    (Server_routes_http.validate_origin (request "/mcp"));
  check (option string) "invalid Origin is never reflected" None
    (Server_auth.public_read_cors_headers h1_prefix_attack
     |> List.assoc_opt "access-control-allow-origin");
  let h2_headers =
    H2.Headers.of_list
      [ ":authority", "127.0.0.1:8935"
      ; "origin", "http://127.0.0.1:8935"
      ]
    |> Server_h2_gateway_helpers.httpun_headers_of_h2
  in
  check (option string) "H2 authority projects to shared Host contract"
    (Some "127.0.0.1:8935")
    (Httpun.Headers.get h2_headers "host");
  let h2_same_origin = Httpun.Request.create ~headers:h2_headers `POST "/mcp" in
  check bool "H2 projected same-origin admitted" true
    (Server_routes_http.validate_origin h2_same_origin);
  let h2_prefix_attack =
    H2.Headers.of_list
      [ ":authority", "127.0.0.1:8935"
      ; "origin", "http://127.0.0.1.evil.test:8935"
      ]
    |> Server_h2_gateway_helpers.httpun_headers_of_h2
    |> fun headers -> Httpun.Request.create ~headers `POST "/mcp"
  in
  check bool "H2 projected origin-prefix attacker rejected" false
    (Server_routes_http.validate_origin h2_prefix_attack);
  check bool "legacy root alias is outside MCP origin gate" false
    (Server_routes_http.is_mcp_like_path "/");
  check bool "canonical MCP path is inside origin gate" true
    (Server_routes_http.is_mcp_like_path "/mcp")

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

let require_sse_owner_lease label = function
  | Ok lease -> lease
  | Error msg -> failf "%s expected a lease, got Error %S" label msg

let assert_sse_owner_claim_error label = function
  | Ok _ -> failf "%s expected Error, got Ok" label
  | Error msg ->
      check bool (label ^ " message is not empty") true (String.length msg > 0)

let admission_identity agent_name role : Server_transport_admission.identity =
  { agent_name; role }

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

let test_session_owner_is_immutable_and_delete_is_owner_or_admin () =
  let session_id = "h1-h2-parity-owned-session" in
  let owner = admission_identity "owner-agent" Masc_domain.Worker in
  let other = admission_identity "other-agent" Masc_domain.Worker in
  let admin = admission_identity "admin-agent" Masc_domain.Admin in
  let initialize_response =
    Mcp_transport_protocol.make_response ~id:(`Int 1) (`Assoc [])
  in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      assert_result_ok "fresh session accepts its first credential owner"
        (Transport.validate_mcp_session_owner_for_request ~session_id
           ~requester:owner);
      assert_result_ok "successful initialize binds credential owner"
        (Transport.bind_mcp_session_owner_if_initialize_succeeded session_id
           ~requester:owner ~request_body:initialize_body
           ~response_json:initialize_response);
      Transport.remember_protocol_version session_id "2025-11-25";
      assert_result_ok "bound owner may reuse session"
        (Transport.validate_mcp_session_owner_for_request ~session_id
           ~requester:owner);
      assert_result_error "different credential cannot reuse session"
        (Transport.validate_mcp_session_owner_for_request ~session_id
           ~requester:other);
      assert_result_error "owner binding cannot be overwritten"
        (Transport.bind_mcp_session_owner_if_initialize_succeeded session_id
           ~requester:other ~request_body:initialize_body
           ~response_json:initialize_response);
      check (option string) "immutable owner remains original"
        (Some owner.agent_name)
        (Transport.mcp_session_owner session_id
         |> Option.map (fun identity -> identity.agent_name));
      assert_result_ok "owner may delete session"
        (Transport.authorize_mcp_session_delete ~session_id ~requester:owner);
      assert_result_error "different worker may not delete session"
        (Transport.authorize_mcp_session_delete ~session_id ~requester:other);
      assert_result_ok "explicit Admin may delete another owner's session"
        (Transport.authorize_mcp_session_delete ~session_id ~requester:admin))

let test_ownerless_known_session_requires_admin_delete () =
  let session_id = "h1-h2-parity-ownerless-session" in
  let worker = admission_identity "worker-agent" Masc_domain.Worker in
  let admin = admission_identity "admin-agent" Masc_domain.Admin in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      Transport.remember_protocol_version session_id "2025-11-25";
      assert_result_error "known ownerless session fails closed on reuse"
        (Transport.validate_mcp_session_owner_for_request ~session_id
           ~requester:worker);
      assert_result_error "known ownerless session cannot open Observer SSE"
        (Transport.validate_mcp_sse_session_owner_for_request ~session_id
           ~sse_kind:Sse.Observer ~requester:worker);
      assert_result_error "worker cannot delete ownerless legacy session"
        (Transport.authorize_mcp_session_delete ~session_id ~requester:worker);
      assert_result_ok "Admin can clean up ownerless legacy session"
        (Transport.authorize_mcp_session_delete ~session_id ~requester:admin))

let test_sse_owner_lease_is_credential_bound_and_stale_safe () =
  let session_id = "h1-h2-parity-ephemeral-sse-session" in
  let owner = admission_identity "observer-owner" Masc_domain.Worker in
  let other = admission_identity "observer-other" Masc_domain.Worker in
  let initialize_response =
    Mcp_transport_protocol.make_response ~id:(`Int 1) (`Assoc [])
  in
  assert_result_error "Agent stream cannot mint an uninitialized session"
    (Transport.validate_mcp_sse_session_owner_for_request ~session_id
       ~sse_kind:Sse.Agent_stream ~requester:owner);
  let first =
    Transport.claim_mcp_sse_session_owner_for_request ~session_id
      ~sse_kind:Sse.Observer ~requester:owner
    |> require_sse_owner_lease "fresh Observer claim"
  in
  ignore (Mcp_store.remove session_id);
  ignore
    (Mcp_store.get_or_create ~id:session_id ~agent_name:owner.agent_name ());
  assert_sse_owner_claim_error
    "same credential cannot overlap an in-progress connection setup"
    (Transport.claim_mcp_sse_session_owner_for_request ~session_id
       ~sse_kind:Sse.Observer ~requester:owner);
  assert_result_ok "registered Observer activates its owner lease"
    (Transport.activate_mcp_sse_owner_lease first);
  assert_result_ok "same credential may validate Observer reconnect"
    (Transport.validate_mcp_sse_session_owner_for_request ~session_id
       ~sse_kind:Sse.Observer ~requester:owner);
  assert_result_error "different credential cannot reuse Observer wire id"
    (Transport.validate_mcp_sse_session_owner_for_request ~session_id
       ~sse_kind:Sse.Observer ~requester:other);
  assert_result_error "POST owner gate also sees the ephemeral SSE owner"
    (Transport.validate_mcp_session_owner_for_request ~session_id
       ~requester:other);
  assert_result_error "successful initialize cannot race a different SSE owner"
    (Transport.bind_mcp_session_owner_if_initialize_succeeded session_id
       ~requester:other ~request_body:initialize_body
       ~response_json:initialize_response);
  check bool "rejected initialize leaves transport owner unbound" true
    (Option.is_none (Transport.mcp_session_owner session_id));
  let abandoned_reconnect =
    Transport.claim_mcp_sse_session_owner_for_request ~session_id
      ~sse_kind:Sse.Observer ~requester:owner
    |> require_sse_owner_lease "same-owner reconnect setup"
  in
  Transport.release_mcp_sse_owner_lease abandoned_reconnect;
  assert_result_error "failed reconnect restores the active owner lease"
    (Transport.validate_mcp_sse_session_owner_for_request ~session_id
       ~sse_kind:Sse.Observer ~requester:other);
  let replacement =
    Transport.claim_mcp_sse_session_owner_for_request ~session_id
      ~sse_kind:Sse.Observer ~requester:owner
    |> require_sse_owner_lease "same-owner Observer reconnect"
  in
  assert_result_ok "replacement Observer activates its owner lease"
    (Transport.activate_mcp_sse_owner_lease replacement);
  Transport.release_mcp_sse_owner_lease first;
  assert_result_error "stale disconnect cannot release replacement lease"
    (Transport.validate_mcp_sse_session_owner_for_request ~session_id
       ~sse_kind:Sse.Observer ~requester:other);
  Transport.release_mcp_sse_owner_lease replacement;
  check bool "current lease release removes fresh owner-bound backing" true
    (Option.is_none (Mcp_store.peek session_id));
  let next_owner =
    Transport.claim_mcp_sse_session_owner_for_request ~session_id
      ~sse_kind:Sse.Presence ~requester:other
    |> require_sse_owner_lease "released id accepts a new Presence owner"
  in
  assert_result_ok "new Presence owner activates its lease"
    (Transport.activate_mcp_sse_owner_lease next_owner);
  Transport.release_mcp_sse_owner_lease next_owner

let test_old_disconnect_during_reconnect_does_not_restore_orphan_owner () =
  let session_id = "h1-h2-parity-sse-disconnect-race" in
  let owner = admission_identity "disconnect-owner" Masc_domain.Worker in
  let other = admission_identity "disconnect-other" Masc_domain.Worker in
  ignore (Mcp_store.remove session_id);
  let active =
    Transport.claim_mcp_sse_session_owner_for_request ~session_id
      ~sse_kind:Sse.Observer ~requester:owner
    |> require_sse_owner_lease "initial race-test claim"
  in
  ignore
    (Mcp_store.get_or_create ~id:session_id ~agent_name:owner.agent_name ());
  assert_result_ok "initial race-test lease activates"
    (Transport.activate_mcp_sse_owner_lease active);
  let reconnect =
    Transport.claim_mcp_sse_session_owner_for_request ~session_id
      ~sse_kind:Sse.Observer ~requester:owner
    |> require_sse_owner_lease "race-test reconnect claim"
  in
  Transport.release_mcp_sse_owner_lease active;
  Transport.release_mcp_sse_owner_lease reconnect;
  check bool "failed reconnect after old disconnect removes backing" true
    (Option.is_none (Mcp_store.peek session_id));
  let other_lease =
    Transport.claim_mcp_sse_session_owner_for_request ~session_id
      ~sse_kind:Sse.Presence ~requester:other
    |> require_sse_owner_lease "race cleanup permits a new owner"
  in
  Transport.release_mcp_sse_owner_lease other_lease

let test_initialized_sse_uses_transport_owner_with_connection_lease () =
  let session_id = "h1-h2-parity-initialized-sse-session" in
  let owner = admission_identity "initialized-owner" Masc_domain.Worker in
  let other = admission_identity "initialized-other" Masc_domain.Worker in
  let initialize_response =
    Mcp_transport_protocol.make_response ~id:(`Int 1) (`Assoc [])
  in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      assert_result_ok "successful initialize binds SSE transport owner"
        (Transport.bind_mcp_session_owner_if_initialize_succeeded session_id
           ~requester:owner ~request_body:initialize_body
           ~response_json:initialize_response);
      Transport.remember_protocol_version session_id "2025-11-25";
      assert_result_ok "initialized owner may open Agent stream"
        (Transport.validate_mcp_sse_session_owner_for_request ~session_id
           ~sse_kind:Sse.Agent_stream ~requester:owner);
      assert_result_error "different owner cannot open initialized Agent stream"
        (Transport.validate_mcp_sse_session_owner_for_request ~session_id
           ~sse_kind:Sse.Agent_stream ~requester:other);
      let lease =
        Transport.claim_mcp_sse_session_owner_for_request ~session_id
          ~sse_kind:Sse.Agent_stream ~requester:owner
        |> require_sse_owner_lease "initialized Agent stream connection claim"
      in
      assert_result_ok "initialized Agent stream activates connection lease"
        (Transport.activate_mcp_sse_owner_lease lease);
      Transport.release_mcp_sse_owner_lease lease)

let test_delete_invalidates_in_flight_agent_stream_claim () =
  let session_id = "h1-h2-parity-delete-vs-agent-get" in
  let owner = admission_identity "delete-race-owner" Masc_domain.Worker in
  let initialize_response =
    Mcp_transport_protocol.make_response ~id:(`Int 1) (`Assoc [])
  in
  Fun.protect
    ~finally:(fun () ->
      Transport.forget_mcp_session session_id;
      ignore (Mcp_store.remove session_id))
    (fun () ->
      assert_result_ok "delete-race initialize binds owner"
        (Transport.bind_mcp_session_owner_if_initialize_succeeded session_id
           ~requester:owner ~request_body:initialize_body
           ~response_json:initialize_response);
      Transport.remember_protocol_version session_id "2025-11-25";
      let lease =
        Transport.claim_mcp_sse_session_owner_for_request ~session_id
          ~sse_kind:Sse.Agent_stream ~requester:owner
        |> require_sse_owner_lease "in-flight Agent GET claim"
      in
      Transport.forget_mcp_session session_id;
      ignore
        (Mcp_store.get_or_create ~id:session_id ~agent_name:owner.agent_name ());
      assert_result_error "deleted Agent GET claim cannot activate"
        (Transport.activate_mcp_sse_owner_lease lease);
      Transport.release_mcp_sse_owner_lease lease;
      check bool "invalidated GET removes backing created after DELETE" true
        (Option.is_none (Mcp_store.peek session_id)))

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
  let owner = admission_identity "failed-initialize-owner" Masc_domain.Worker in
  Fun.protect
    ~finally:(fun () -> Transport.forget_mcp_session session_id)
    (fun () ->
      Transport.remember_protocol_version_if_initialize_succeeded
        ~otel_transport_context:transport_context
        session_id
        ~request_body
        ~response_json;
      assert_result_ok "failed initialize does not attempt owner binding"
        (Transport.bind_mcp_session_owner_if_initialize_succeeded session_id
           ~requester:owner ~request_body ~response_json);
      check bool "failed initialize leaves session unknown" false
        (Transport.is_known_session session_id);
      check bool "failed initialize leaves owner unbound" true
        (Option.is_none (Transport.mcp_session_owner session_id));
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
      ( "requires strict credential admission",
        "authorize_mcp_profile_admission" );
      ( "checks immutable session owner",
        "validate_mcp_session_owner_for_request" );
      ( "binds owner after successful initialize",
        "bind_mcp_session_owner_if_initialize_succeeded" );
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
    ~needle:"~status:`Not_found" h2;
  assert_not_contains "H2 does not expose legacy POST / MCP alias"
    ~needle:{|`POST, "/"|}
    h2

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
      ("requires strict credential admission", "authorize_mcp_profile_admission");
      ("checks session profile", "validate_mcp_session_delete_profile");
      ("checks owner or Admin", "authorize_mcp_session_delete");
      ("checks protocol continuity", "validate_protocol_version_continuity");
      ("forgets session after termination", "forget_mcp_session session_id");
    ];
  assert_contains "H1 invalidates session before stopping DELETE connection"
    ~needle:"forget_mcp_session session_id;\n               stop_sse_session session_id"
    h1;
  assert_contains "H2 invalidates session before stopping DELETE connection"
    ~needle:
      "Server_mcp_transport_http.forget_mcp_session\n                               session_id;\n                             stop_sse_session session_id"
    h2

let test_mcp_sse_get_owner_wiring_and_fail_closed_route_surface () =
  let h1 = source_file "lib/server/server_mcp_transport_http.ml" in
  let related_sse =
    source_file "lib/server/server_mcp_transport_http_agui.ml"
  in
  let h1_routes = source_file "lib/server/server_routes_http_routes_frontend.ml" in
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  let get_handler =
    source_between ~start_anchor:"let handle_get_mcp"
      ~end_anchor:"let handle_get_operator_mcp" h1
  in
  List.iter
    (fun (label, needle) -> assert_contains label ~needle get_handler)
    [
      ( "GET requires strict profile admission",
        "authorize_mcp_profile_admission" );
      ( "GET validates stream-specific session ownership",
        "validate_mcp_sse_session_owner_for_request" );
      ( "GET claims fresh Observer or Presence ownership",
        "claim_mcp_sse_session_owner_for_request" );
      ( "GET binds the backing session to the credential owner",
        "ensure_sse_backing_session_for_owner" );
      ( "GET activates ownership only after SSE registration",
        "activate_mcp_sse_owner_lease" );
      ( "GET clears the prior disconnect hook",
        "Sse.clear_disconnect_hook session_id" );
      ( "GET closes only after admission and ownership",
        "stop_sse_session_preserve_guard session_id" );
    ];
  assert_order "GET authenticates before owner validation"
    ~before:"authorize_mcp_profile_admission"
    ~after:"validate_mcp_sse_session_owner_for_request" get_handler;
  assert_order "GET validates owner before claiming the wire id"
    ~before:"validate_mcp_sse_session_owner_for_request"
    ~after:"claim_mcp_sse_session_owner_for_request" get_handler;
  assert_order "GET claims owner before stopping an existing connection"
    ~before:"claim_mcp_sse_session_owner_for_request"
    ~after:"stop_sse_session_preserve_guard session_id" get_handler;
  assert_order "GET clears stale hook before stopping existing connection"
    ~before:"Sse.clear_disconnect_hook session_id"
    ~after:"stop_sse_session_preserve_guard session_id" get_handler;
  assert_order "GET publishes HTTP connection before activating its owner lease"
    ~before:"register_sse_conn ~session_id ~info"
    ~after:"activate_mcp_sse_owner_lease" get_handler;
  List.iter
    (fun (label, needle) -> assert_contains label ~needle related_sse)
    [
      ( "AG-UI/Presence require strict bearer admission",
        "authorize_token_bound_admission_request" );
      ( "AG-UI/Presence validate owner before guard/stop",
        "validate_mcp_sse_session_owner_for_request" );
      ( "AG-UI/Presence claim shared SSE owner lease",
        "claim_mcp_sse_session_owner_for_request" );
      ( "AG-UI/Presence bind credential owner to backing",
        "ensure_backing_session_for_owner" );
      ( "AG-UI/Presence clear stale hook before reconnect stop",
        "Sse.clear_disconnect_hook session_id" );
      ( "AG-UI/Presence publish before owner activation",
        "register_sse_conn ~session_id ~info" );
      ( "Presence validates raw transport owner before namespace claim",
        "~related_transport_session_id:raw_session_id" );
    ];
  assert_order "related SSE authenticates before owner validation"
    ~before:"authorize_token_bound_admission_request"
    ~after:"validate_mcp_sse_session_owner_for_request" related_sse;
  assert_order "related SSE owner claim precedes reconnect stop"
    ~before:"claim_mcp_sse_session_owner_for_request"
    ~after:"stop_sse_session_preserve_guard session_id" related_sse;
  assert_order "related SSE publishes before owner activation"
    ~before:"register_sse_conn ~session_id ~info"
    ~after:"Sse_owner.activate lease" related_sse;
  assert_not_contains "related SSE no longer uses unit legacy auth"
    ~needle:"verify_mcp_observer_stream_auth" related_sse;
  assert_contains "H1 exposes the single implemented SSE GET ingress"
    ~needle:{|Http.Router.get "/mcp"|} h1_routes;
  assert_not_contains "H1 managed GET remains fail closed"
    ~needle:{|Http.Router.get "/mcp/managed"|} h1_routes;
  assert_not_contains "H1 legacy /sse GET remains fail closed"
    ~needle:{|Http.Router.get "/sse"|} h1_routes;
  assert_contains "H1 AG-UI SSE route uses the owned handler"
    ~needle:{|Http.Router.get "/ag-ui/events" handle_ag_ui_events|}
    h1_routes;
  assert_contains "H1 Presence SSE route uses the owned handler"
    ~needle:{|Http.Router.get "/events/presence" handle_presence_events|}
    h1_routes;
  assert_not_contains "H2 /mcp GET remains fail closed"
    ~needle:{|`GET, "/mcp"|} h2;
  assert_not_contains "H2 managed GET remains fail closed"
    ~needle:{|`GET, "/mcp/managed"|} h2;
  assert_not_contains "H2 legacy /sse GET remains fail closed"
    ~needle:{|`GET, "/sse"|} h2;
  assert_not_contains "H2 AG-UI SSE remains fail closed"
    ~needle:{|`GET, "/ag-ui/events"|} h2;
  assert_not_contains "H2 Presence SSE remains fail closed"
    ~needle:{|`GET, "/events/presence"|} h2

let test_h2_read_auth_and_origin_wiring_parity () =
  let h1_frontend =
    source_file "lib/server/server_routes_http_routes_frontend.ml"
  in
  let h1_dashboard =
    source_file "lib/server/server_routes_http_routes_dashboard.ml"
  in
  let h1_activity =
    source_file "lib/server/server_routes_http_routes_activity.ml"
  in
  let h1_ide = source_file "lib/server/server_ide_http.ml" in
  let h2 = source_file "lib/server/server_h2_gateway.ml" in
  let h2_extra =
    source_file "lib/server/server_h2_gateway_routes_extra.ml"
  in
  let h2_helpers =
    source_file "lib/server/server_h2_gateway_helpers.ml"
  in
  let common = source_file "lib/server/server_routes_http_common.ml" in
  let h1_runtime = source_file "lib/server/server_routes_http_runtime.ml" in
  let h1_main = source_file "bin/main_eio.ml" in
  assert_contains "H1 GraphQL SSOT uses strict read admission"
    ~needle:
      "with_read_auth (fun _state req reqd -> handle_graphql req reqd)"
    h1_frontend;
  List.iter
    (fun (path, source) ->
      assert_contains ("H1 public-read SSOT for " ^ path)
        ~needle:(Printf.sprintf "Http.Router.get %S" path) source;
      assert_near_after ("H1 public-read wrapper guards " ^ path)
        ~anchor:(Printf.sprintf "Http.Router.get %S" path)
        ~needle:"with_public_read" ~within:160 source)
    [ "/api/v1/dashboard/branches", h1_dashboard
    ; "/api/v1/dashboard/nudges", h1_dashboard
    ; "/api/v1/dashboard/workspace", h1_dashboard
    ; "/api/v1/status", h1_ide
    ; "/api/v1/voice/config", h1_frontend
    ; "/api/v1/board", h1_activity
    ; "/api/v1/karma", h1_activity
    ];
  List.iter
    (fun path ->
      assert_contains ("H2 public-read admission for " ^ path)
        ~needle:
          (Printf.sprintf "`GET, %S ->\n          with_h2_public_read" path)
        h2)
    [ "/api/v1/dashboard/branches"
    ; "/api/v1/dashboard/nudges"
    ; "/api/v1/dashboard/workspace"
    ; "/api/v1/status"
    ; "/api/v1/openapi.json"
    ];
  assert_contains "H2 strict read admission for GET /graphql"
    ~needle:"`GET, \"/graphql\" ->\n          with_h2_read_auth" h2;
  assert_contains "H2 strict read admission for POST /graphql"
    ~needle:"`POST, \"/graphql\" ->\n          with_h2_read_auth" h2;
  assert_contains "H2 agent-card read uses public-read admission"
    ~needle:
      {|`GET, ("/.well-known/agent.json" | "/.well-known/agent-card.json") ->
          with_h2_public_read|}
    h2;
  List.iter
    (fun path ->
      assert_contains ("H2 extra public-read admission for " ^ path)
        ~needle:
          (Printf.sprintf "| `GET, %S ->\n      handle_public_read" path)
        h2_extra)
    [ "/api/v1/voice/config"
    ; "/api/v1/board"
    ; "/api/v1/board/curation"
    ; "/api/v1/board/hearths"
    ; "/api/v1/board/flairs"
    ; "/api/v1/board/sub-boards"
    ; "/api/v1/board/karma/ledger"
    ; "/api/v1/karma"
    ];
  assert_contains "H2 board detail read uses public-read admission"
    ~needle:{|&& String.length p > 14 ->
      handle_public_read|}
    h2_extra;
  assert_contains "H2 extra dispatcher receives parent public-read adapter"
    ~needle:"Server_h2_gateway_routes_extra.dispatch\n               ~with_public_read:"
    h2;
  assert_contains "H2 projects :authority into the shared Host contract"
    ~needle:"let httpun_headers = httpun_headers_of_h2 h2_headers" h2;
  assert_contains "H2 authority projection is owned by one helper"
    ~needle:"H2.Headers.get headers \":authority\"" h2_helpers;
  assert_contains "H2 CORS reflection reuses H1 safe headers"
    ~needle:"let cors = public_read_cors_headers httpun_request" h2;
  assert_contains "H2 MCP Origin gate reuses the shared predicate"
    ~needle:
      "if is_mcp_like_path path && not (validate_origin httpun_request)"
    h2;
  assert_contains "H1 aliases the shared MCP path predicate"
    ~needle:"let is_mcp_like_path = Server_routes_http.is_mcp_like_path"
    h1_main;
  assert_contains "shared Origin admission uses parsed H1 CORS policy"
    ~needle:"| Some _ -> Option.is_some (public_read_cors_origin_opt request)"
    common;
  assert_not_contains "shared Origin admission has no prefix heuristic"
    ~needle:"String.starts_with ~prefix origin" common;
  assert_contains "H1 preflight uses safe CORS reflection"
    ~needle:"public_read_cors_headers request" h1_runtime;
  assert_not_contains "H2 preflight does not reflect raw Origin"
    ~needle:"cors_preflight_headers origin" h2

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

let hex_encode value =
  let buffer = Buffer.create (String.length value * 2) in
  String.iter (fun byte -> Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte))) value;
  Buffer.contents buffer

let ws_upgrade_request ?token headers =
  let headers =
    match token with
    | None -> headers
    | Some token ->
      ( "sec-websocket-protocol"
      , "masc.dashboard.v1, " ^ Server_auth.websocket_bearer_subprotocol_prefix
        ^ hex_encode token )
      :: headers
  in
  Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET "/ws"

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

let test_ws_upgrade_rejects_legacy_query_bearer () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  let request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [ ("host", "127.0.0.1:8935")
           ; ("origin", "http://127.0.0.1:8935")
           ])
      `GET
      ("/ws?token=" ^ Uri.pct_encode token)
  in
  match
    Server_routes_http_routes_frontend.websocket_upgrade_authorized
      ~base_path
      request
  with
  | Ok _ -> fail "legacy query bearer must not authenticate a WebSocket"
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

let test_ws_upgrade_rejects_browser_subprotocol_cross_origin () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  match
    ws_gate
      ~token
      ~base_path
      [ ("host", "127.0.0.1:8935"); ("origin", "http://evil.example:8935") ]
  with
  | Ok _ -> fail "browser subprotocol credential must be origin-bound"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf "expected Auth error, got %s" (Masc_domain.masc_error_to_string other)

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

let test_ws_upgrade_rejects_ambiguous_subprotocol_credentials () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  let request =
    ws_upgrade_request
      [ ( "sec-websocket-protocol"
        , "masc.dashboard.v1, masc.bearer.hex.zz, "
          ^ Server_auth.websocket_bearer_subprotocol_prefix
          ^ hex_encode token )
      ; ("host", "127.0.0.1:8935")
      ; ("origin", "http://127.0.0.1:8935")
      ]
  in
  match
    Server_routes_http_routes_frontend.websocket_upgrade_authorized
      ~base_path
      request
  with
  | Ok _ -> fail "multiple credential subprotocols must fail closed"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf "expected Auth error, got %s" (Masc_domain.masc_error_to_string other)

let test_ws_upgrade_rejects_conflicting_credential_channels () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  let request =
    ws_upgrade_request
      ~token
      [ ("host", "127.0.0.1:8935")
      ; ("origin", "http://127.0.0.1:8935")
      ; ("authorization", "Bearer " ^ token)
      ]
  in
  match
    Server_routes_http_routes_frontend.websocket_upgrade_authorized
      ~base_path
      request
  with
  | Ok _ -> fail "multiple credential channels must fail closed"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf "expected Auth error, got %s" (Masc_domain.masc_error_to_string other)

let test_ws_upgrade_rejects_process_wide_internal_token () =
  with_ws_auth_dir @@ fun base_path ->
  let internal_token = Auth.ensure_internal_keeper_token base_path in
  let request =
    ws_upgrade_request
      [ ("host", "127.0.0.1:8935")
      ; ("authorization", "Bearer " ^ internal_token)
      ; ("x-masc-keeper-name", "sangsu")
      ]
  in
  match
    Server_routes_http_routes_frontend.websocket_upgrade_authorized
      ~base_path
      request
  with
  | Ok _ -> fail "process-wide internal token must not impersonate a keeper"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf
      "expected Auth error, got %s"
      (Masc_domain.masc_error_to_string other)

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
             ( "sec-websocket-protocol"
             , "masc.ide.v1, " ^ Server_auth.websocket_bearer_subprotocol_prefix
               ^ hex_encode token );
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

let webrtc_admission_request ?token () =
  let headers =
    match token with
    | None -> [ "origin", "http://127.0.0.1:8935" ]
    | Some token ->
      [ "origin", "http://127.0.0.1:8935"
      ; "authorization", "Bearer " ^ token
      ]
  in
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `POST
    "/webrtc/offer"

let test_webrtc_signaling_denies_tokenless_same_origin () =
  with_ws_auth_dir @@ fun base_path ->
  match
    Server_auth.authorize_token_bound_admission_request
      ~base_path
      ~permission:Masc_domain.CanBroadcast
      (webrtc_admission_request ())
  with
  | Ok _ -> fail "same-origin WebRTC signaling must not replace bearer admission"
  | Error (Masc_domain.Auth _) -> ()
  | Error other ->
    failf
      "expected Auth error, got %s"
      (Masc_domain.masc_error_to_string other)

let test_webrtc_signaling_retains_bearer_owner () =
  with_ws_auth_dir @@ fun base_path ->
  let token = worker_token base_path in
  match
    Server_auth.authorize_token_bound_admission_request
      ~base_path
      ~permission:Masc_domain.CanBroadcast
      (webrtc_admission_request ~token ())
  with
  | Ok admission ->
    check string "credential owner" "ws-test-agent" admission.identity.agent_name;
    check string "retained bearer" token admission.auth_token
  | Error err ->
    failf
      "expected bearer-authenticated WebRTC signaling, got %s"
      (Masc_domain.masc_error_to_string err)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "mcp_h1_h2_admission_parity"
    [
      ( "shared-admission-matrix",
        [
          test_case "request context records pre-body state" `Quick
            test_request_context_make_records_session_source;
          test_case "Origin admission is exact across H1/H2" `Quick
            test_origin_admission_is_exact_across_h1_h2;
          test_case "request context decides POST body admission" `Quick
            test_request_context_decides_post_body;
          test_case "POST shared predicate matrix" `Quick
            test_shared_post_admission_matrix;
          test_case "protocol and DELETE predicate matrix" `Quick
            test_shared_protocol_and_delete_matrix;
          test_case "session owner is immutable; delete is owner or Admin" `Quick
            test_session_owner_is_immutable_and_delete_is_owner_or_admin;
          test_case "ownerless known session requires Admin delete" `Quick
            test_ownerless_known_session_requires_admin_delete;
          test_case "ephemeral SSE owner lease is credential-bound and stale-safe"
            `Quick test_sse_owner_lease_is_credential_bound_and_stale_safe;
          test_case "old disconnect during reconnect cannot orphan owner" `Quick
            test_old_disconnect_during_reconnect_does_not_restore_orphan_owner;
          test_case "initialized SSE reuses immutable transport owner" `Quick
            test_initialized_sse_uses_transport_owner_with_connection_lease;
          test_case "DELETE invalidates in-flight Agent GET claim" `Quick
            test_delete_invalidates_in_flight_agent_stream_claim;
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
          test_case "MCP SSE GET ownership and route surface fail closed" `Quick
            test_mcp_sse_get_owner_wiring_and_fail_closed_route_surface;
          test_case "H2 read auth and Origin wiring match H1" `Quick
            test_h2_read_auth_and_origin_wiring_parity;
        ] );
      ( "ws-upgrade-admission",
        [
          test_case "denies same-origin upgrade without token" `Quick
            test_ws_upgrade_denied_without_token;
          test_case "rejects legacy query bearer" `Quick
            test_ws_upgrade_rejects_legacy_query_bearer;
          test_case "allows token-bound same-origin upgrade" `Quick
            test_ws_upgrade_allows_token_bound_same_origin;
          test_case "rejects cross-origin browser subprotocol credential" `Quick
            test_ws_upgrade_rejects_browser_subprotocol_cross_origin;
          test_case "allows bearer header for non-browser clients" `Quick
            test_ws_upgrade_allows_bearer_header_for_non_browser_client;
          test_case "rejects ambiguous subprotocol credentials" `Quick
            test_ws_upgrade_rejects_ambiguous_subprotocol_credentials;
          test_case "rejects conflicting credential channels" `Quick
            test_ws_upgrade_rejects_conflicting_credential_channels;
          test_case "rejects process-wide internal token impersonation" `Quick
            test_ws_upgrade_rejects_process_wide_internal_token;
          test_case "carries admitted bearer into MCP dispatcher" `Quick
            test_ws_dispatch_carries_admitted_bearer;
          test_case "IDE LSP denies tokenless same-origin upgrade" `Quick
            test_ide_lsp_websocket_denies_tokenless_same_origin;
          test_case "IDE LSP allows token-bound same-origin upgrade" `Quick
            test_ide_lsp_websocket_allows_token_bound_same_origin;
        ] );
      ( "webrtc-admission",
        [
          test_case "denies tokenless same-origin signaling" `Quick
            test_webrtc_signaling_denies_tokenless_same_origin;
          test_case "retains signaling bearer owner" `Quick
            test_webrtc_signaling_retains_bearer_owner;
        ] );
    ]
