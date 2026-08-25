open Alcotest
module Transport_headers = Server_mcp_transport_http_headers

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
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let module Session = Server_mcp_transport_http in
  let session_id = "compat-session-missing-header" in
  let headers = Httpun.Headers.of_list [] in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  Session.remember_protocol_version session_id "2025-11-25";
  Fun.protect
    ~finally:(fun () -> Session.forget_mcp_session session_id)
    (fun () ->
      match Session.validate_protocol_version_continuity ~session_id request with
      | Ok () -> ()
      | Error rejection ->
          failf "expected missing protocol header to use session continuity, got %s"
            (Session.protocol_version_rejection_message rejection))

let test_protocol_version_for_session_falls_back_to_negotiated_version () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let module Session = Server_mcp_transport_http in
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
  let module Session = Server_mcp_transport_http in
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
      | Error (Session.Session_version_mismatch { expected; got; _ }) ->
          check string "remembered version" "2025-11-25" expected;
          check string "requested version" "2025-03-26" got
      | Error (Session.Unsupported_version { requested }) ->
          failf
            "expected a session mismatch, got an unsupported-version \
             rejection for %s"
            requested)

(* The rejection a modern client reads to decide this server is modern. The
   assertion runs through the transport rather than the error module so the
   supported list the body advertises stays the list the transport actually
   validates against. *)
let test_unsupported_protocol_version_rejection () =
  let module Session = Server_mcp_transport_http in
  let session_id = "compat-session-unsupported-version" in
  let headers =
    Httpun.Headers.of_list [("mcp-protocol-version", "1900-01-01")]
  in
  let request = Httpun.Request.create ~headers `POST "/mcp" in
  match Session.validate_protocol_version_continuity ~session_id request with
  | Ok () -> fail "expected an unsupported protocol version to be rejected"
  | Error (Session.Session_version_mismatch _) ->
      fail "an unknown session cannot produce a continuity mismatch"
  | Error (Session.Unsupported_version { requested } as rejection) ->
      check string "requested version is echoed" "1900-01-01" requested;
      let body = Session.protocol_version_rejection_body rejection in
      let advertised =
        match Yojson.Safe.from_string body with
        | `Assoc fields -> (
            match List.assoc_opt "error" fields with
            | Some (`Assoc err) -> (
                (match List.assoc_opt "code" err with
                | Some (`Int code) ->
                    check int "wire code fixed by MCP 2026-07-28" (-32022) code
                | _ -> fail "error.code missing from the body");
                match List.assoc_opt "data" err with
                | Some (`Assoc data) -> (
                    match List.assoc_opt "supported" data with
                    | Some (`List vs) ->
                        List.filter_map
                          (function `String s -> Some s | _ -> None)
                          vs
                    | _ -> fail "data.supported missing from the body")
                | _ -> fail "error.data missing from the body")
            | _ -> fail "error object missing from the body")
        | _ -> fail "rejection body is not a JSON object"
      in
      check (list string) "body advertises exactly what the transport accepts"
        Mcp_transport_protocol.supported_protocol_versions advertised

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

(* 2026-07-28 marks protocolVersion and clientCapabilities required on every
   request and answers a missing one with -32602, not with the header-mismatch
   code: the request is malformed rather than inconsistent with itself. *)
let stateless_body_without meta_key =
  let full = Yojson.Safe.from_string (stateless_body ()) in
  let strip_meta = function
    | `Assoc meta -> `Assoc (List.remove_assoc meta_key meta)
    | other -> other
  in
  let strip_params = function
    | `Assoc params ->
      `Assoc
        (List.map
           (fun (k, v) -> if String.equal k "_meta" then (k, strip_meta v) else (k, v))
           params)
    | other -> other
  in
  match full with
  | `Assoc fields ->
    Yojson.Safe.to_string
      (`Assoc
        (List.map
           (fun (k, v) ->
             if String.equal k "params" then (k, strip_params v) else (k, v))
           fields))
  | other -> Yojson.Safe.to_string other

let test_a_required_meta_field_is_rejected_as_invalid_params () =
  let request =
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
  List.iter
    (fun key ->
      let body = stateless_body_without key in
      match Transport_headers.validate_2026_request_headers request body with
      | Ok () -> failf "a request without %s must be rejected" key
      | Error (Transport_headers.Missing_required_meta { key = reported }) ->
        check string "names the field that was missing" key reported;
        let wire = Transport_headers.header_rejection_body body
                     (Transport_headers.Missing_required_meta { key }) in
        check int "answered with Invalid params" (-32602)
          Yojson.Safe.Util.(
            Yojson.Safe.from_string wire |> member "error" |> member "code"
            |> to_int)
      | Error _ ->
        failf "%s is absent, not inconsistent -- that is -32602, not a mismatch"
          key)
    [ Mcp_transport_protocol.protocol_version_meta_key;
      Mcp_transport_protocol.client_capabilities_meta_key ]

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
  | Error _ -> fail "these headers mirror the body and must be accepted");
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
  | Error _ -> fail "Mcp-Name mirrors params.name and must be accepted");
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
  (* The constructor, not a substring of the message. The kind is what decides
     the wire code, and a message reworded for a human used to be able to
     change what this test proved. *)
  | Error (Transport_headers.Mirrored_header_mismatch msg) ->
      check bool "names the header that disagreed" true
        (String_util.contains_substring msg "Mcp-Method")
  | Error _ -> fail "a readable body disagreeing with a header is a mirrored mismatch"

let test_stateless_headers_do_not_emit_session_id () =
  let module Transport = Server_mcp_transport_http in
  let headers = Transport.mcp_headers "session-x" "2026-07-28" in
  check (option string) "no mcp-session-id"
    None
    (List.assoc_opt "mcp-session-id" headers);
  check (option string) "keeps protocol version"
    (Some "2026-07-28")
    (List.assoc_opt "mcp-protocol-version" headers)

(* The transport reads these from Env_config_runtime, not from its own
   Sys.getenv_opt (#28910). Pinned so a local read cannot come back and drift
   from the value the rest of the server resolves.  Since task-538 the
   transport reads through the [Re_read] thunks (per-call), so this compares
   the cached config binding against the thunk the transport actually
   calls. *)
let test_sse_guard_knobs_come_from_the_config_module () =
  let module Conn = Server_mcp_transport_http_conn in
  let module Cfg = Env_config_runtime.Sse_connect_guard in
  check (float 0.0) "min reconnect interval" Cfg.reconnect_min_interval_seconds
    (Conn.sse_reconnect_min_interval_s ());
  check (float 0.0) "connect window" Cfg.connect_window_seconds
    (Conn.sse_connect_window_s ());
  check int "max in window" Cfg.connect_max_in_window
    (Conn.sse_connect_max_in_window ())
;;

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

(* task-534: the SSE reconnect guard's documented disable semantics are
   "[<= 0]" — negative {e and} zero both disable (mli of
   Env_config_runtime.Sse_connect_guard, docs/spec/09-server-transport.md,
   and Server_mcp_transport_http_conn.mli all say so).  A reader that
   routes these three knobs through the [*_nonneg] helpers would clamp a
   negative to the default and silently turn "disable" back into
   "default cooldown", with every doc still claiming otherwise.  These
   tests pin the reader itself: the raw value comes through, whatever its
   sign.  They use the [Re_read] thunks, which since task-538 are the same
   readers the production transport calls — the transport's [sse_*] bindings
   are these thunks, so a clamp anywhere in the live path turns these
   checks red too. *)
let with_env_var name value f =
  let prev = Sys.getenv_opt name in
  Unix.putenv name value;
  let finally () =
    match prev with
    | Some v -> Unix.putenv name v
    | None -> Unix.putenv name ""
  in
  Fun.protect ~finally f

let test_sse_guard_negative_disables_not_clamped () =
  let module Reread = Env_config_runtime.Sse_connect_guard.Re_read in
  with_env_var "MASC_SSE_RECONNECT_MIN_INTERVAL_S" "-1" @@ fun () ->
  check (float 0.0) "negative min-interval reads through (-1.0)" (-1.0)
    (Reread.reconnect_min_interval_seconds ());
  with_env_var "MASC_SSE_CONNECT_WINDOW_S" "-0.5" @@ fun () ->
  check (float 0.0) "negative window reads through (-0.5)" (-0.5)
    (Reread.connect_window_seconds ());
  with_env_var "MASC_SSE_CONNECT_MAX_IN_WINDOW" "-3" @@ fun () ->
  check int "negative max-in-window reads through (-3)" (-3)
    (Reread.connect_max_in_window ())

let test_sse_guard_zero_and_positive_read_through () =
  let module Reread = Env_config_runtime.Sse_connect_guard.Re_read in
  with_env_var "MASC_SSE_RECONNECT_MIN_INTERVAL_S" "0" @@ fun () ->
  check (float 0.0) "zero min-interval reads through (0.0)" 0.0
    (Reread.reconnect_min_interval_seconds ());
  with_env_var "MASC_SSE_CONNECT_WINDOW_S" "30" @@ fun () ->
  check (float 0.0) "positive window reads through (30.0)" 30.0
    (Reread.connect_window_seconds ());
  with_env_var "MASC_SSE_CONNECT_MAX_IN_WINDOW" "5" @@ fun () ->
  check int "positive max-in-window reads through (5)" 5
    (Reread.connect_max_in_window ())

(* Non-vacuous note: the guard's decision logic ([guard_deadline] /
   [check_sse_connect_guard]) answers "disabled" exactly when the knob is
   [<= 0.0]; that branch is already exercised by the two cooldown tests
   above, and the reader tests here pin the other half of the contract —
   that a negative value reaches that branch instead of being clamped to
   the default by the reader.  A [*_nonneg] reader swap turns these three
   checks red while every doc still says "[<= 0] disables". *)

(* task-538: pin the {e production path} end-to-end.  The two tests above
   pin the reader in isolation; this one drives the transport's real entry
   point, {!Server_mcp_transport_http.check_sse_connect_guard}, with all
   three knobs set negative.  Two classes of regression turn this check
   red: a cached-binding regression (toplevel bindings fixed at process
   start still hold the ambient positive value, so the guard would reject
   a reconnect the operator asked to allow), and a [min_interval_s] clamp
   to the positive default (a successful connect records
   [last_connect_at], so the second call would return
   [Session_cooldown]).  A [connect_window_s] or [connect_max_in_window]
   clamp alone does {e not} turn this red — two connects stay under the
   default [max_in_window] threshold — which is why those two knobs keep
   their isolated reader tests above. *)
let test_sse_guard_negative_disables_in_production_path () =
  let module Transport = Server_mcp_transport_http in
  with_env_var "MASC_SSE_RECONNECT_MIN_INTERVAL_S" "-1" @@ fun () ->
  with_env_var "MASC_SSE_CONNECT_WINDOW_S" "-0.5" @@ fun () ->
  with_env_var "MASC_SSE_CONNECT_MAX_IN_WINDOW" "-3" @@ fun () ->
  let session_id = "sse-guard-negative-disable-e2e" in
  (* Prime the guard so a second connect would be rejected if any knob
     still clamped to its positive default. *)
  (match Transport.check_sse_connect_guard session_id with
  | Error (reason, wait_s) ->
      failf "first connect under disabled guard rejected: %s %.3f"
        (Sse_reject_reason.to_label reason) wait_s
  | Ok () -> ());
  match Transport.check_sse_connect_guard session_id with
  | Error (reason, wait_s) ->
      failf "disable semantics did not reach the guard: %s %.3f"
        (Sse_reject_reason.to_label reason) wait_s
  | Ok () -> ()

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "http_negotiation"    [
      ("accepts_sse_header", [test_case "parses Accept" `Quick test_accepts_sse_header]);
      ("accepts_streamable_mcp", [test_case "requires json+sse" `Quick test_accepts_streamable_mcp]);
      ("classify_mcp_accept", [test_case "strict classification" `Quick test_classify_mcp_accept]);
      ("is_json_content_type", [test_case "content-type contract" `Quick test_is_json_content_type]);
      ("protocol_continuity", [
        test_case "missing header falls back to session" `Quick test_protocol_continuity_allows_missing_header;
        test_case "remembered session version is reused" `Quick test_protocol_version_for_session_falls_back_to_negotiated_version;
        test_case "mismatch still rejects" `Quick test_protocol_continuity_rejects_mismatch;
        test_case "unsupported version answers -32022" `Quick
          test_unsupported_protocol_version_rejection;
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
          test_case "a missing required _meta field is invalid params" `Quick
            test_a_required_meta_field_is_rejected_as_invalid_params;
        test_case "2026 headers omit session id" `Quick
          test_stateless_headers_do_not_emit_session_id;
        test_case "sse guard registry is shared" `Quick
          test_sse_guard_registry_is_shared_with_cleanup_loop;
        test_case "preserve guard keeps cooldown" `Quick
          test_preserve_guard_keeps_ag_ui_cooldown;
        test_case "sse guard knobs come from the config module" `Quick
          test_sse_guard_knobs_come_from_the_config_module;
      ]);
      ("sse_guard_disable_semantics", [
        test_case "negative reads through, not clamped to default" `Quick
          test_sse_guard_negative_disables_not_clamped;
        test_case "zero and positive read through unchanged" `Quick
          test_sse_guard_zero_and_positive_read_through;
        test_case "negative disable holds in the production guard path" `Quick
          test_sse_guard_negative_disables_in_production_path;
      ]);
    ]
