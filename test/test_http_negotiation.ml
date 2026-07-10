open Alcotest

module Session = Server_mcp_transport_http
module Store = Server_mcp_transport_session_store

let with_initialized_session ~session_id ~protocol_version f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "masc-http-negotiation-" "" in
  Eio.Switch.run @@ fun cleanup_sw ->
  Eio.Switch.on_release cleanup_sw (fun () -> Fs_compat.remove_tree base_path);
  Eio.Switch.run @@ fun store_sw ->
  match Store.open_ ~sw:store_sw ~base_path with
  | Error error ->
      failf "failed to open explicit session store: %s"
        (Store.open_error_to_string error)
  | Ok sessions ->
      let initialized_at = Unix.gettimeofday () in
      let session : Store.session =
        {
          session_id;
          protocol_version;
          tool_profile = Session.Full;
          owner =
            {
              Server_transport_admission.agent_name =
                "http-negotiation-owner";
              role = Masc_domain.Worker;
          };
          started_at = initialized_at;
          transport_context = None;
        }
      in
      (match Store.initialize sessions session with
      | Error error ->
          failf "failed to initialize explicit session: %s"
            (Store.mutation_error_to_string error)
      | Ok () -> (
          match Store.find sessions ~session_id with
          | Some (Store.Stable_state (Store.Active _)) -> f sessions
          | Some
              (Store.Pending_state
                { indeterminate; intended = Store.Active _ }) ->
              failf "initialized session is durability-pending: %s"
                (Store.mutation_error_to_string
                   (Store.Persistence_indeterminate indeterminate))
          | Some (Store.Pending_state { intended = Store.Deleted _; _ }) ->
              fail "initialized session unexpectedly has a pending tombstone"
          | Some (Store.Stable_state (Store.Deleted _)) ->
              fail "initialized session unexpectedly resolved to a tombstone"
          | None -> fail "initialized session is absent from Store.find"))

let test_accepts_sse_header () =
  let open Mcp_transport_protocol.Http_negotiation in
  check bool "missing accept" false (accepts_sse_header None);
  check bool "application/json" false (accepts_sse_header (Some "application/json"));
  check bool "wildcard only" false (accepts_sse_header (Some "*/*"));
  check bool "event-stream exact" true (accepts_sse_header (Some "text/event-stream"));
  check bool "event-stream with params" true (accepts_sse_header (Some "text/event-stream; charset=utf-8"));
  check bool "event-stream not first" true (accepts_sse_header (Some "application/json, text/event-stream"));
  check bool "event-stream q=0" false (accepts_sse_header (Some "text/event-stream;q=0"));
  check bool "case-insensitive" true (accepts_sse_header (Some "Text/Event-Stream"));
  ()

let test_accepts_streamable_mcp () =
  let open Mcp_transport_protocol.Http_negotiation in
  check bool "missing accept" false (accepts_streamable_mcp None);
  check bool "json only" false (accepts_streamable_mcp (Some "application/json"));
  check bool "sse only" false (accepts_streamable_mcp (Some "text/event-stream"));
  check bool "wildcard only" false (accepts_streamable_mcp (Some "*/*"));
  check bool "json + sse" true (accepts_streamable_mcp (Some "application/json, text/event-stream"));
  check bool "json + sse reversed" true (accepts_streamable_mcp (Some "text/event-stream, application/json"));
  check bool "sse q=0" false (accepts_streamable_mcp (Some "application/json, text/event-stream;q=0"));
  check bool "case-insensitive" true (accepts_streamable_mcp (Some "Application/Json, Text/Event-Stream"));
  ()

let test_classify_mcp_accept () =
  let open Mcp_transport_protocol.Http_negotiation in
  let check_mode label expected actual =
    let same =
      match (expected, actual) with
      | Streamable, Streamable
      | Rejected, Rejected ->
          true
      | _ -> false
    in
    check bool label true same
  in
  check_mode "strict streamable"
    Streamable
    (classify_mcp_accept (Some "application/json, text/event-stream"));
  check_mode "strict reject"
    Rejected
    (classify_mcp_accept (Some "text/event-stream"));
  ()

let test_is_json_content_type () =
  let open Mcp_transport_protocol.Http_negotiation in
  let check_json label expected value =
    check bool label expected (is_json_content_type (Some value))
  in
  check bool "missing content-type" false (is_json_content_type None);
  check_json "exact" true "application/json";
  check_json "with charset" true "application/json; charset=utf-8";
  check_json "case-insensitive" true "Application/JSON";
  check_json "quoted param with comma" true "application/json; boundary=\"a,b\"";
  check_json "quoted param with semicolon" true "application/json; boundary=\"a;b\"";
  check_json "reject q param" false "application/json;q=0.5";
  check_json "reject malformed q param" false "application/json; q";
  check_json "reject malformed param" false "application/json; boundary";
  check_json "reject comma list" false "application/json, text/plain";
  check_json "reject json-seq suffix" false "application/json-seq";
  check_json "reject json5 suffix" false "application/json5";
  check_json "reject ld+json suffix" false "application/ld+json";
  check_json "reject text/plain" false "text/plain";
  ()

let test_protocol_continuity_allows_missing_header () =
  let session_id = "compat-session-missing-header" in
  let headers = Httpun.Headers.of_list [] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  with_initialized_session ~session_id ~protocol_version:"2025-11-25"
    (fun sessions ->
      match
        Session.validate_protocol_version_continuity ~sessions ~session_id
          request
      with
      | Ok () -> ()
      | Error msg ->
          failf "expected missing protocol header to use session continuity, got %s" msg)

let test_protocol_version_for_session_falls_back_to_negotiated_version () =
  let session_id = "compat-session-negotiated-version" in
  let headers = Httpun.Headers.of_list [] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  with_initialized_session ~session_id ~protocol_version:"2025-03-26"
    (fun sessions ->
      check string "falls back to remembered session version" "2025-03-26"
        (Session.get_protocol_version_for_session ~sessions ~session_id request))

let test_protocol_continuity_rejects_mismatch () =
  let session_id = "compat-session-mismatch" in
  let headers =
    Httpun.Headers.of_list [("mcp-protocol-version", "2025-03-26")]
  in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  with_initialized_session ~session_id ~protocol_version:"2025-11-25"
    (fun sessions ->
      match
        Session.validate_protocol_version_continuity ~sessions ~session_id
          request
      with
      | Ok () -> fail "expected mismatched protocol version to be rejected"
      | Error msg ->
          check bool "mentions mismatch" true
            (String.length msg > 0
            && String.contains msg ':'))

let test_notification_json_only_rejected () =
  let module Transport = Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [("accept", "application/json")] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let mode = Transport.classify_mcp_accept request in
  check bool "notification json-only is rejected" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Rejected -> true
    | _ -> false)

let test_request_json_only_accepted () =
  (* JSON-only Accept no longer qualifies as streamable MCP and should be rejected. *)
  let module Transport = Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [("accept", "application/json")] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let mode = Transport.classify_mcp_accept request in
  check bool "json-only accept is rejected" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Rejected -> true
    | _ -> false)

let test_initialize_json_only_accepted () =
  (* Initialize with JSON-only Accept is also rejected under the stricter transport rule. *)
  let module Transport = Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [("accept", "application/json")] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let mode = Transport.classify_mcp_accept request in
  check bool "initialize with json-only is rejected" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Rejected -> true
    | _ -> false)

let test_no_accept_header_rejected () =
  (* No Accept header at all should still be Rejected *)
  let module Transport = Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let mode = Transport.classify_mcp_accept request in
  check bool "no accept header is rejected" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Rejected -> true
    | _ -> false)

let test_initialize_never_uses_sse () =
  let module Transport = Server_mcp_transport_http in
  let headers =
    Httpun.Headers.of_list
      [("accept", "application/json, text/event-stream")]
  in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let body =
    {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}|}
  in
  check bool "initialize disables sse" false
    (Transport.should_use_sse_for_body request body
       Mcp_transport_protocol.Http_negotiation.Streamable)

let stateless_body ?(method_ = "tools/list") ?name () =
  let params_fields =
    [ ( "_meta",
        `Assoc
          [
            ( Mcp_transport_protocol.protocol_version_meta_key,
              `String "2026-07-28" );
            ( "io.modelcontextprotocol/clientInfo",
              `Assoc
                [ ("name", `String "http-test"); ("version", `String "0.1") ]
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

let test_validate_2026_request_headers () =
  let module Transport = Server_mcp_transport_http in
  let ok_request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [
             ("accept", "application/json, text/event-stream");
             ("mcp-protocol-version", "2026-07-28");
             ("mcp-method", "tools/list");
           ])
      `POST "/mcp"
  in
  (match Transport.validate_2026_request_headers ok_request (stateless_body ()) with
  | Ok () -> ()
  | Error msg -> failf "expected valid 2026 headers, got %s" msg);
  let tool_call_request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [
             ("accept", "application/json, text/event-stream");
             ("mcp-protocol-version", "2026-07-28");
             ("mcp-method", "tools/call");
             ("mcp-name", "masc_status");
           ])
      `POST "/mcp"
  in
  (match
     Transport.validate_2026_request_headers tool_call_request
       (stateless_body ~method_:"tools/call" ~name:"masc_status" ())
   with
  | Ok () -> ()
  | Error msg -> failf "expected valid Mcp-Name headers, got %s" msg);
  let mismatch_request =
    Httpun.Request.create
      ~headers:
        (Httpun.Headers.of_list
           [
             ("accept", "application/json, text/event-stream");
             ("mcp-protocol-version", "2026-07-28");
             ("mcp-method", "resources/list");
           ])
      `POST "/mcp"
  in
  match Transport.validate_2026_request_headers mismatch_request (stateless_body ()) with
  | Ok () -> fail "expected mismatched Mcp-Method to reject"
  | Error msg ->
      check bool "mentions header mismatch" true
        (String_util.contains_substring msg "HeaderMismatch")

let test_stateless_headers_do_not_emit_session_id () =
  let module Transport = Server_mcp_transport_http in
  let headers = Transport.mcp_headers "session-x" "2026-07-28" in
  check (option string) "no mcp-session-id"
    None
    (List.assoc_opt "mcp-session-id" headers);
  check (option string) "keeps protocol version"
    (Some "2026-07-28")
    (List.assoc_opt "mcp-protocol-version" headers)

let test_sse_guard_registry_is_shared_with_cleanup_loop () =
  let module Transport = Server_mcp_transport_http in
  let module Cleanup_view = Server_mcp_transport_http_sse in
  let session_id = "shared-sse-guard-registry" in
  match Transport.check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      failf "expected first guard insert to succeed, got %s %.3f"
        (Sse_reject_reason.to_label reason)
        retry_after_s
  | Ok () ->
      check int "cleanup keeps fresh guard entries" 0
        (Cleanup_view.reap_stale_guards ());
      (match Transport.check_sse_connect_guard session_id with
      | Error (Sse_reject_reason.Session_cooldown, retry_after_s) ->
          check bool "cooldown stays positive" true (retry_after_s > 0.0)
      | Error (reason, retry_after_s) ->
          failf "expected shared cooldown guard, got %s %.3f"
            (Sse_reject_reason.to_label reason)
            retry_after_s
      | Ok () ->
          fail "expected second guard check to observe shared cooldown state")

let test_preserve_guard_keeps_ag_ui_cooldown () =
  let module Transport = Server_mcp_transport_http in
  let module Cleanup_view = Server_mcp_transport_http_sse in
  let session_id = "ag-ui-preserve-guard" in
  match Transport.check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      failf "expected first guard insert to succeed, got %s %.3f"
        (Sse_reject_reason.to_label reason)
        retry_after_s
  | Ok () ->
      Cleanup_view.stop_sse_session_preserve_guard session_id;
      (match Transport.check_sse_connect_guard session_id with
      | Ok () -> fail "expected preserved guard to enforce reconnect cooldown"
      | Error (reason, retry_after_s) ->
          check string "preserves session cooldown reason"
            "session_cooldown"
            (Sse_reject_reason.to_label reason);
          check bool "preserved retry-after is positive" true (retry_after_s > 0.0));
      ignore (Cleanup_view.reap_stale_guards ())

let () =
  run "http_negotiation"
    [
      ("accepts_sse_header", [test_case "parses Accept" `Quick test_accepts_sse_header]);
      ("accepts_streamable_mcp", [test_case "requires json+sse" `Quick test_accepts_streamable_mcp]);
      ("classify_mcp_accept", [test_case "strict classification" `Quick test_classify_mcp_accept]);
      ("is_json_content_type", [test_case "content-type contract" `Quick test_is_json_content_type]);
      ("protocol_continuity", [
        test_case "missing header falls back to session" `Quick test_protocol_continuity_allows_missing_header;
        test_case "remembered session version is reused" `Quick test_protocol_version_for_session_falls_back_to_negotiated_version;
        test_case "mismatch still rejects" `Quick test_protocol_continuity_rejects_mismatch;
      ]);
      ("accept_contract", [
        test_case "notification json-only rejected" `Quick
          test_notification_json_only_rejected;
        test_case "json-only accept is rejected" `Quick test_request_json_only_accepted;
        test_case "initialize json-only is rejected" `Quick test_initialize_json_only_accepted;
        test_case "no accept header rejected" `Quick test_no_accept_header_rejected;
        test_case "initialize disables sse" `Quick test_initialize_never_uses_sse;
        test_case "2026 headers are validated" `Quick
          test_validate_2026_request_headers;
        test_case "2026 headers omit session id" `Quick
          test_stateless_headers_do_not_emit_session_id;
        test_case "sse guard registry is shared" `Quick
          test_sse_guard_registry_is_shared_with_cleanup_loop;
        test_case "preserve guard keeps cooldown" `Quick
          test_preserve_guard_keeps_ag_ui_cooldown;
      ]);
    ]
