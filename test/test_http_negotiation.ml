open Alcotest

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
      | Legacy_accepted, Legacy_accepted
      | Rejected, Rejected ->
          true
      | _ -> false
    in
    check bool label true same
  in
  check_mode "strict streamable"
    Streamable
    (classify_mcp_accept ~allow_legacy:false
       (Some "application/json, text/event-stream"));
  check_mode "legacy accepted"
    Legacy_accepted
    (classify_mcp_accept ~allow_legacy:true (Some "text/event-stream"));
  check_mode "strict reject"
    Rejected
    (classify_mcp_accept ~allow_legacy:false (Some "text/event-stream"));
  ()

let test_protocol_continuity_allows_missing_header () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let module Session = Masc_mcp.Server_mcp_transport_http in
  let session_id = "compat-session-missing-header" in
  let headers = Httpun.Headers.of_list [] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  Session.remember_protocol_version session_id "2025-11-25";
  Fun.protect
    ~finally:(fun () -> Session.forget_mcp_session session_id)
    (fun () ->
      match Session.validate_protocol_version_continuity ~session_id request with
      | Ok () -> ()
      | Error msg ->
          failf "expected missing protocol header to use session continuity, got %s" msg)

let test_protocol_version_for_session_falls_back_to_negotiated_version () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let module Session = Masc_mcp.Server_mcp_transport_http in
  let session_id = "compat-session-negotiated-version" in
  let headers = Httpun.Headers.of_list [] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  Session.remember_protocol_version session_id "2025-03-26";
  Fun.protect
    ~finally:(fun () -> Session.forget_mcp_session session_id)
    (fun () ->
      check string "falls back to remembered session version" "2025-03-26"
        (Session.get_protocol_version_for_session ~session_id request))

let test_protocol_continuity_rejects_mismatch () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let module Session = Masc_mcp.Server_mcp_transport_http in
  let session_id = "compat-session-mismatch" in
  let headers =
    Httpun.Headers.of_list [("mcp-protocol-version", "2025-03-26")]
  in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  Session.remember_protocol_version session_id "2025-11-25";
  Fun.protect
    ~finally:(fun () -> Session.forget_mcp_session session_id)
    (fun () ->
      match Session.validate_protocol_version_continuity ~session_id request with
      | Ok () -> fail "expected mismatched protocol version to be rejected"
      | Error msg ->
          check bool "mentions mismatch" true
            (String.length msg > 0
            && String.contains msg ':'))

let test_notification_body_relaxes_accept () =
  let module Transport = Masc_mcp.Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [("accept", "application/json")] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let body =
    {|{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}|}
  in
  let mode = Transport.classify_mcp_accept_for_body request body in
  check bool "notification legacy accepted" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Legacy_accepted -> true
    | _ -> false)

let test_request_json_only_accepted () =
  (* JSON-only Accept no longer qualifies as streamable MCP and should be rejected. *)
  let module Transport = Masc_mcp.Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [("accept", "application/json")] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let body =
    {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}|}
  in
  let mode = Transport.classify_mcp_accept_for_body request body in
  check bool "json-only accept is rejected" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Rejected -> true
    | _ -> false)

let test_initialize_json_only_accepted () =
  (* Initialize with JSON-only Accept is also rejected under the stricter transport rule. *)
  let module Transport = Masc_mcp.Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [("accept", "application/json")] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let body =
    {|{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0.1"}}}|}
  in
  let mode = Transport.classify_mcp_accept_for_body request body in
  check bool "initialize with json-only is rejected" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Rejected -> true
    | _ -> false)

let test_no_accept_header_rejected () =
  (* No Accept header at all should still be Rejected *)
  let module Transport = Masc_mcp.Server_mcp_transport_http in
  let headers = Httpun.Headers.of_list [] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  let body =
    {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}|}
  in
  let mode = Transport.classify_mcp_accept_for_body request body in
  check bool "no accept header is rejected" true
    (match mode with
    | Mcp_transport_protocol.Http_negotiation.Rejected -> true
    | _ -> false)

let test_initialize_never_uses_sse () =
  let module Transport = Masc_mcp.Server_mcp_transport_http in
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

let test_sse_guard_registry_is_shared_with_cleanup_loop () =
  let module Transport = Masc_mcp.Server_mcp_transport_http in
  let module Cleanup_view = Masc_mcp.Server_mcp_transport_http_sse in
  let session_id = "shared-sse-guard-registry" in
  match Transport.check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      failf "expected first guard insert to succeed, got %s %.3f" reason
        retry_after_s
  | Ok () ->
      check int "cleanup keeps fresh guard entries" 0
        (Cleanup_view.reap_stale_guards ());
      (match Transport.check_sse_connect_guard session_id with
      | Error ("session_cooldown", retry_after_s) ->
          check bool "cooldown stays positive" true (retry_after_s > 0.0)
      | Error (reason, retry_after_s) ->
          failf "expected shared cooldown guard, got %s %.3f" reason retry_after_s
      | Ok () ->
          fail "expected second guard check to observe shared cooldown state")

let test_preserve_guard_keeps_ag_ui_cooldown () =
  let module Transport = Masc_mcp.Server_mcp_transport_http in
  let module Cleanup_view = Masc_mcp.Server_mcp_transport_http_sse in
  let session_id = "ag-ui-preserve-guard" in
  match Transport.check_sse_connect_guard session_id with
  | Error (reason, retry_after_s) ->
      failf "expected first guard insert to succeed, got %s %.3f" reason
        retry_after_s
  | Ok () ->
      Cleanup_view.stop_sse_session_preserve_guard session_id;
      (match Transport.check_sse_connect_guard session_id with
      | Ok () -> fail "expected preserved guard to enforce reconnect cooldown"
      | Error (reason, retry_after_s) ->
          check string "preserves session cooldown reason" "session_cooldown" reason;
          check bool "preserved retry-after is positive" true (retry_after_s > 0.0));
      ignore (Cleanup_view.reap_stale_guards ())

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "http_negotiation"
    [
      ("accepts_sse_header", [test_case "parses Accept" `Quick test_accepts_sse_header]);
      ("accepts_streamable_mcp", [test_case "requires json+sse" `Quick test_accepts_streamable_mcp]);
      ("classify_mcp_accept", [test_case "strict vs legacy fallback" `Quick test_classify_mcp_accept]);
      ("protocol_continuity", [
        test_case "missing header falls back to session" `Quick test_protocol_continuity_allows_missing_header;
        test_case "remembered session version is reused" `Quick test_protocol_version_for_session_falls_back_to_negotiated_version;
        test_case "mismatch still rejects" `Quick test_protocol_continuity_rejects_mismatch;
      ]);
      ("body_aware_accept", [
        test_case "notification relaxes accept" `Quick test_notification_body_relaxes_accept;
        test_case "json-only accept is rejected" `Quick test_request_json_only_accepted;
        test_case "initialize json-only is rejected" `Quick test_initialize_json_only_accepted;
        test_case "no accept header rejected" `Quick test_no_accept_header_rejected;
        test_case "initialize disables sse" `Quick test_initialize_never_uses_sse;
        test_case "sse guard registry is shared" `Quick
          test_sse_guard_registry_is_shared_with_cleanup_loop;
        test_case "preserve guard keeps cooldown" `Quick
          test_preserve_guard_keeps_ag_ui_cooldown;
      ]);
    ]
