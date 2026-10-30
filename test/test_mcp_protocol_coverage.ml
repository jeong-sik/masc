(** Mcp_transport_protocol wrapper tests.

    Parsing/matching logic is delegated to Mcp_protocol.Http_negotiation (SDK).
    These tests verify the string-option wrapper, accept_mode classification,
    and wildcard handling via SDK. *)

open Alcotest

module Http_negotiation = Mcp_transport_protocol.Http_negotiation

(* ============================================================
   Content Type Constants Tests
   ============================================================ *)

let test_sse_content_type () =
  check string "sse content type" "text/event-stream" Http_negotiation.sse_content_type

let test_json_content_type () =
  check string "json content type" "application/json" Http_negotiation.json_content_type

let test_default_protocol_version () =
  check string "default protocol version" "2025-11-25"
    Mcp_transport_protocol.default_protocol_version

let test_supported_protocol_versions () =
  check bool "current version included" true
    (List.mem "2025-11-25" Mcp_transport_protocol.supported_protocol_versions)

let test_supported_protocol_versions_includes_2026_stateless () =
  check bool "2026 stateless version included" true
    (List.mem "2026-07-28"
       Mcp_transport_protocol.supported_protocol_versions);
  check bool "draft alias included" true
    (List.mem "DRAFT-2026-v1"
       Mcp_transport_protocol.supported_protocol_versions);
  check bool "2026 is stateless" true
    (Mcp_transport_protocol.is_stateless_protocol_version "2026-07-28");
  check bool "draft alias is stateless" true
    (Mcp_transport_protocol.is_stateless_protocol_version "DRAFT-2026-v1")

let test_protocol_version_from_params_none () =
  check string "none falls back to default" "2025-11-25"
    (Mcp_transport_protocol.protocol_version_from_params None)

let test_protocol_version_from_params_present () =
  check string "params version" "2025-03-26"
    (Mcp_transport_protocol.protocol_version_from_params
       (Some (`Assoc [ ("protocolVersion", `String "2025-03-26") ])))

let test_protocol_version_from_body_initialize () =
  check (option string) "initialize body version" (Some "2025-06-18")
    (Mcp_transport_protocol.protocol_version_from_body
       {|{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2025-06-18"}}|})

let test_protocol_version_from_body_invalid_normalizes () =
  check (option string) "invalid initialize version normalizes"
    (Some "2025-11-25")
    (Mcp_transport_protocol.protocol_version_from_body
       {|{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2099-01-01"}}|})

let test_initialize_does_not_negotiate_a_stateless_version () =
  check (option string) "modern proposal gets a legacy counter-offer"
    (Some "2025-11-25")
    (Mcp_transport_protocol.protocol_version_from_body
       {|{"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":"2026-07-28"}}|})

(* The latest differs from the newest legacy entry, so the result tells a kept
   latest from the fallback. *)
let test_legacy_default_keeps_a_legacy_latest () =
  check (result string string) "a legacy latest is the counter-offer"
    (Ok "2025-06-18")
    (Mcp_transport_protocol.legacy_default_protocol_version_of
       ~latest:"2025-06-18"
       ~supported:
         [ "2026-07-28"; "DRAFT-2026-v1"; "2024-11-05"; "2025-06-18"; "2025-11-25" ])

(* The counter-offer given differs from the SDK's latest, so a fallback that
   reads the SDK's default instead fails here. *)
let test_negotiate_legacy_uses_the_given_counter_offer () =
  let negotiate =
    Mcp_transport_protocol.negotiate_legacy_protocol_version_with
      ~legacy_default:"2025-06-18"
  in
  check string "a legacy proposal is kept" "2024-11-05" (negotiate "2024-11-05");
  check string "a stateless proposal gets the counter-offer" "2025-06-18"
    (negotiate "2026-07-28");
  check string "an unknown proposal gets the counter-offer" "2025-06-18"
    (negotiate "1999-01-01");
  check string "the exported function counters with the legacy default"
    Mcp_transport_protocol.legacy_default_protocol_version
    (Mcp_transport_protocol.negotiate_legacy_protocol_version "2026-07-28")

let test_legacy_default_skips_a_stateless_latest () =
  check (result string string) "a stateless latest falls back to the newest legacy"
    (Ok "2025-11-25")
    (Mcp_transport_protocol.legacy_default_protocol_version_of
       ~latest:"2026-07-28"
       ~supported:[ "2026-07-28"; "DRAFT-2026-v1"; "2024-11-05"; "2025-11-25" ])

let test_legacy_default_needs_a_legacy_version () =
  check bool "no legacy version is an error" true
    (Result.is_error
       (Mcp_transport_protocol.legacy_default_protocol_version_of
          ~latest:"2026-07-28" ~supported:[ "2026-07-28"; "DRAFT-2026-v1" ]))

(* The fallback takes the last legacy entry as the newest, so the SDK has to
   list legacy versions oldest first. A reordered SDK list fails here. *)
let test_legacy_default_matches_the_sdk () =
  check string "legacy counter-offer today" "2025-11-25"
    Mcp_transport_protocol.legacy_default_protocol_version;
  let legacy =
    List.filter
      (fun version -> not (Mcp_transport_protocol.is_stateless_protocol_version version))
      Mcp_transport_protocol.supported_protocol_versions
  in
  check (list string) "legacy versions are listed oldest first"
    (List.sort String.compare legacy) legacy

let test_protocol_version_from_body_non_initialize () =
  check (option string) "non-initialize ignored" None
    (Mcp_transport_protocol.protocol_version_from_body
       {|{"jsonrpc":"2.0","method":"tools/list"}|})

let test_protocol_version_from_body_missing_jsonrpc () =
  check (option string) "missing jsonrpc rejected" None
    (Mcp_transport_protocol.protocol_version_from_body
       {|{"method":"initialize","params":{"protocolVersion":"2025-06-18"}}|})

let test_protocol_version_from_request_meta_body () =
  check (option string) "request meta version" (Some "2026-07-28")
    (Mcp_transport_protocol.protocol_version_from_request_meta_body
       {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}|});
  check bool "body uses stateless protocol" true
    (Mcp_transport_protocol.body_uses_stateless_protocol
       {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}|})

let test_request_protocol_admission () =
  let module P = Mcp_transport_protocol in
  let classify ?(require_stateless = false) ?(method_ = "tools/list") params =
    P.classify_request_protocol ~require_stateless ~method_ ~params
  in
  let params version caps =
    Some (`Assoc [ "_meta", `Assoc
      [ P.protocol_version_meta_key, version
      ; P.client_capabilities_meta_key, caps ] ])
  in
  let invalid_meta = function
    | Error (P.Invalid_request_meta _) -> true
    | Error (P.Unsupported_request_version _)
    | Ok (P.Legacy_protocol | P.Stateless_protocol _) -> false
  in
  check bool "legacy request remains legacy" true
    (classify None = Ok P.Legacy_protocol);
  check bool "uninitialized stdio requires modern metadata" true
    (invalid_meta (classify ~require_stateless:true None));
  check bool "discover requires modern metadata even after initialization" true
    (invalid_meta (classify ~method_:"server/discover" None));
  check bool "valid modern request" true
    (classify (params (`String "2026-07-28") (`Assoc []))
     = Ok (P.Stateless_protocol "2026-07-28"));
  check bool "unsupported version is identifiable" true
    (classify (params (`String "2099-01-01") (`Assoc []))
     = Error (P.Unsupported_request_version "2099-01-01"));
  check bool "capabilities must be an object" true
    (invalid_meta (classify (params (`String "2026-07-28") (`String "roots"))));
  check bool "legacy versions are not per-request versions" true
    (invalid_meta (classify (params (`String "2025-11-25") (`Assoc []))));
  check bool "duplicate version fields are invalid" true
    (invalid_meta (classify (Some (`Assoc [ "_meta", `Assoc
       [ P.protocol_version_meta_key, `String "2026-07-28"
       ; P.protocol_version_meta_key, `String "2099-01-01"
       ; P.client_capabilities_meta_key, `Assoc [] ] ]))))

let test_request_null_id_is_not_a_notification () =
  let request = `Assoc
    [ "jsonrpc", `String "2.0"; "id", `Null; "method", `String "tools/list"
    ; "params", `Null ] in
  match Mcp_transport_protocol.jsonrpc_request_of_yojson request with
  | Error detail -> fail detail
  | Ok parsed ->
    check bool "explicit null is retained" true (parsed.id = Some `Null);
    check bool "explicit null params are retained" true (parsed.params = Some `Null);
    check bool "null ID is not a notification" false
      (Mcp_transport_protocol.is_notification parsed)

(* ============================================================
   accepts_json Tests (new: delegates to SDK with wildcard support)
   ============================================================ *)

let test_accepts_json_none () =
  check bool "None" false (Http_negotiation.accepts_json None)

let test_accepts_json_exact () =
  check bool "exact" true
    (Http_negotiation.accepts_json (Some "application/json"))

let test_accepts_json_not_found () =
  check bool "xml" false
    (Http_negotiation.accepts_json (Some "text/html"))

let test_accepts_json_wildcard () =
  check bool "*/* matches json" true
    (Http_negotiation.accepts_json (Some "*/*"))

let test_accepts_json_in_list () =
  check bool "json in list" true
    (Http_negotiation.accepts_json (Some "text/html, application/json"))

let test_accepts_json_case_insensitive () =
  check bool "mixed-case json" true
    (Http_negotiation.accepts_json (Some "Application/Json"))

(* ============================================================
   is_json_content_type Tests
   ============================================================ *)

let test_json_content_type_none () =
  check bool "None" false (Http_negotiation.is_json_content_type None)

let test_json_content_type_exact () =
  check bool "exact" true
    (Http_negotiation.is_json_content_type (Some "application/json"))

let test_json_content_type_with_params () =
  check bool "params" true
    (Http_negotiation.is_json_content_type
       (Some "application/json; charset=utf-8"))

let test_json_content_type_case_insensitive () =
  check bool "mixed-case" true
    (Http_negotiation.is_json_content_type (Some "Application/Json"))

let test_json_content_type_rejects_jsonp () =
  check bool "jsonp" false
    (Http_negotiation.is_json_content_type (Some "application/jsonp"))

let test_json_content_type_rejects_wildcard () =
  check bool "wildcard" false
    (Http_negotiation.is_json_content_type (Some "*/*"))

let test_json_content_type_rejects_accept_list () =
  check bool "list" false
    (Http_negotiation.is_json_content_type
       (Some "application/json, text/event-stream"))

(* ============================================================
   accepts_sse_header Tests
   ============================================================ *)

let test_accepts_sse_none () =
  check bool "None" false (Http_negotiation.accepts_sse_header None)

let test_accepts_sse_json_only () =
  check bool "json only" false
    (Http_negotiation.accepts_sse_header (Some "application/json"))

let test_accepts_sse_wildcard () =
  (* SSE requires explicit opt-in; */* does not imply SSE readiness *)
  check bool "wildcard" false
    (Http_negotiation.accepts_sse_header (Some "*/*"))

let test_accepts_sse_exact () =
  check bool "exact" true
    (Http_negotiation.accepts_sse_header (Some "text/event-stream"))

let test_accepts_sse_with_q () =
  check bool "with q=0.5" true
    (Http_negotiation.accepts_sse_header (Some "text/event-stream;q=0.5"))

let test_accepts_sse_q_zero () =
  check bool "q=0 rejected" false
    (Http_negotiation.accepts_sse_header (Some "text/event-stream;q=0"))

let test_accepts_sse_case_insensitive () =
  check bool "mixed-case sse" true
    (Http_negotiation.accepts_sse_header (Some "Text/Event-Stream"))

(* ============================================================
   accepts_streamable_mcp Tests
   ============================================================ *)

let test_streamable_none () =
  check bool "None" false (Http_negotiation.accepts_streamable_mcp None)

let test_streamable_json_only () =
  check bool "json only" false
    (Http_negotiation.accepts_streamable_mcp (Some "application/json"))

let test_streamable_sse_only () =
  check bool "sse only" false
    (Http_negotiation.accepts_streamable_mcp (Some "text/event-stream"))

let test_streamable_both () =
  check bool "both" true
    (Http_negotiation.accepts_streamable_mcp
      (Some "application/json, text/event-stream"))

let test_streamable_both_reversed () =
  check bool "reversed" true
    (Http_negotiation.accepts_streamable_mcp
      (Some "text/event-stream, application/json"))

let test_streamable_json_q_zero () =
  check bool "json q=0" false
    (Http_negotiation.accepts_streamable_mcp
      (Some "application/json;q=0, text/event-stream"))

let test_streamable_sse_q_zero () =
  check bool "sse q=0" false
    (Http_negotiation.accepts_streamable_mcp
      (Some "application/json, text/event-stream;q=0"))

let test_streamable_case_insensitive () =
  check bool "mixed-case streamable" true
    (Http_negotiation.accepts_streamable_mcp
      (Some "Application/Json, Text/Event-Stream"))

(* ============================================================
   classify_mcp_accept Tests
   ============================================================ *)

let test_classify_streamable () =
  let mode =
    Http_negotiation.classify_mcp_accept
      (Some "application/json, text/event-stream")
  in
  check bool "streamable mode" true
    (match mode with Http_negotiation.Streamable -> true | _ -> false)

let test_classify_rejected () =
  let mode =
    Http_negotiation.classify_mcp_accept (Some "text/event-stream")
  in
  check bool "rejected mode" true
    (match mode with Http_negotiation.Rejected -> true | _ -> false)

let test_classify_none_rejected () =
  let mode = Http_negotiation.classify_mcp_accept None in
  check bool "none rejected" true
    (match mode with Http_negotiation.Rejected -> true | _ -> false)

let test_classify_wildcard_rejected () =
  (* */* alone: json=true but sse=false, so not Streamable *)
  let mode = Http_negotiation.classify_mcp_accept (Some "*/*") in
  check bool "wildcard rejected" true
    (match mode with Http_negotiation.Rejected -> true | _ -> false)

(* ============================================================
   Test Runners
   ============================================================ *)


(* ============================================================
   make_response resultType (SEP-2322, revision 2026-07-28)
   ============================================================ *)

let result_member resp =
  match resp with
  | `Assoc fields -> List.assoc_opt "result" fields
  | _ -> None

let result_type_of fields =
  match List.assoc_opt "resultType" fields with
  | Some (`String s) -> Some s
  | _ -> None

let test_make_response_adds_complete () =
  let resp =
    Mcp_transport_protocol.make_response ~id:(`Int 1) (`Assoc [ "ok", `Bool true ])
  in
  match result_member resp with
  | Some (`Assoc fields) ->
    check (option string) "resultType defaults to complete" (Some "complete")
      (result_type_of fields);
    check bool "original members preserved" true (List.mem_assoc "ok" fields)
  | _ -> fail "result must remain an object"

let test_make_response_preserves_existing_result_type () =
  let resp =
    Mcp_transport_protocol.make_response ~id:(`Int 2)
      (`Assoc [ "resultType", `String "input_required" ])
  in
  match result_member resp with
  | Some (`Assoc fields) ->
    check (option string) "an explicit resultType is not overwritten"
      (Some "input_required") (result_type_of fields);
    check int "resultType appears once" 1
      (List.length (List.filter (fun (k, _) -> String.equal k "resultType") fields))
  | _ -> fail "result must remain an object"

let test_make_response_envelope_intact () =
  let resp = Mcp_transport_protocol.make_response ~id:(`Int 7) (`Assoc []) in
  match resp with
  | `Assoc fields ->
    check (option string) "jsonrpc version" (Some "2.0")
      (match List.assoc_opt "jsonrpc" fields with
       | Some (`String v) -> Some v
       | _ -> None);
    check bool "id echoed" true
      (match List.assoc_opt "id" fields with Some (`Int 7) -> true | _ -> false)
  | _ -> fail "response must be an object"

(* 2026-07-28 has a server identify itself in every result's _meta. Asserted on
   [make_response] rather than at a handler, because that is the one seam every
   result passes through -- the same reason [resultType] is injected there. *)
let test_every_result_carries_the_server_identity () =
  let meta_of result =
    Yojson.Safe.Util.(
      Mcp_transport_protocol.make_response ~id:(`Int 1) result
      |> member "result" |> member "_meta"
      |> member Mcp_transport_protocol.server_info_meta_key)
  in
  Alcotest.(check bool)
    "a bare result gains the key"
    true
    (meta_of (`Assoc [ ("ok", `Bool true) ])
     = Mcp_transport_protocol.server_info_meta_value);
  Alcotest.(check bool)
    "an existing _meta keeps its other keys"
    true
    Yojson.Safe.Util.(
      Mcp_transport_protocol.make_response ~id:(`Int 1)
        (`Assoc [ ("_meta", `Assoc [ ("mine", `Int 7) ]) ])
      |> member "result" |> member "_meta" |> member "mine"
      = `Int 7);
  (* A handler that already identified itself is left alone -- the injection
     fills a gap, it does not overwrite an answer. *)
  Alcotest.(check bool)
    "a handler's own serverInfo survives"
    true
    (meta_of
       (`Assoc
         [ ( "_meta"
           , `Assoc
               [ (Mcp_transport_protocol.server_info_meta_key, `String "theirs")
               ] )
         ])
     = `String "theirs")
;;

(* The identity has one owner: restating name or version in the handshake is
   how [Runtime_build_version] says a connector's literal drifted before. *)
let test_handshake_identity_comes_from_the_same_place () =
  let field name json = Yojson.Safe.Util.(json |> member name) in
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "%s matches the per-result identity" name)
        true
        (field name Masc.Mcp_server.server_info
         = field name Mcp_transport_protocol.server_info_meta_value))
    [ "name"; "title"; "version" ]
;;

module Subs = Mcp_subscriptions
module TP = Mcp_transport_protocol

let listen_params json = Some (`Assoc [ ("notifications", json) ])

(* "All fields are optional. Omitting a field is equivalent to not subscribing
   to that notification type." An absent object is a subscription to nothing,
   not an error. *)
let test_an_absent_filter_subscribes_to_nothing () =
  let f = TP.subscription_filter_of_params None in
  Alcotest.(check bool) "nothing is on" true
    (f = TP.empty_subscription_filter);
  Alcotest.(check bool) "an empty notifications object is the same" true
    (TP.subscription_filter_of_params (listen_params (`Assoc []))
     = TP.empty_subscription_filter)

(* The acknowledgement reports the subset the server honours, and a type that
   was not asked for is absent rather than false. *)
let test_the_acknowledged_filter_omits_what_was_not_asked_for () =
  let f =
    TP.subscription_filter_of_params
      (listen_params (`Assoc [ ("toolsListChanged", `Bool true) ]))
  in
  Alcotest.(check string)
    "only the requested type appears"
    {|{"toolsListChanged":true}|}
    (Yojson.Safe.to_string (TP.subscription_filter_to_json f))

let test_a_notification_carries_the_subscription_id () =
  let tagged =
    TP.tag_notification_with_subscription ~subscription_id:(`Int 7)
      (TP.jsonrpc_notification "notifications/tools/list_changed")
  in
  Alcotest.(check string)
    "the id of the listen request rides in params._meta"
    "7"
    (Yojson.Safe.to_string
       Yojson.Safe.Util.(
         tagged |> member "params" |> member "_meta"
         |> member TP.subscription_id_meta_key))

(* The server MUST NOT send a type the client did not request. Asserted by
   opening two streams that asked for different things and counting what each
   one received. *)
let test_a_stream_receives_only_what_it_asked_for () =
  Subs.reset_for_test ();
  let tools_got = ref 0 and resource_got = ref 0 in
  let tools_only =
    TP.subscription_filter_of_params
      (listen_params (`Assoc [ ("toolsListChanged", `Bool true) ]))
  in
  let resource_only =
    TP.subscription_filter_of_params
      (listen_params
         (`Assoc
           [ ("resourceSubscriptions", `List [ `String "masc://status" ]) ]))
  in
  let _ =
    Subs.register ~subscription_id:(`Int 1) ~filter:tools_only
      ~send:(fun _ -> incr tools_got; true)
  in
  let _ =
    Subs.register ~subscription_id:(`Int 2) ~filter:resource_only
      ~send:(fun _ -> incr resource_got; true)
  in
  Subs.notify_tools_list_changed
    (TP.jsonrpc_notification "notifications/tools/list_changed");
  Alcotest.(check int) "the tools stream got it" 1 !tools_got;
  Alcotest.(check int) "the resource stream did not" 0 !resource_got;
  Subs.notify_resource_updated ~uri:"masc://status"
    (TP.jsonrpc_notification "notifications/resources/updated");
  Alcotest.(check int) "the resource stream got its uri" 1 !resource_got;
  Subs.notify_resource_updated ~uri:"masc://other"
    (TP.jsonrpc_notification "notifications/resources/updated");
  Alcotest.(check int) "a uri it did not name does not reach it" 1 !resource_got;
  Subs.reset_for_test ()

(* A send that fails means the peer is gone. Retiring the entry there keeps a
   dead stream from being retried on every later notification. *)
let test_a_dead_stream_is_retired () =
  Subs.reset_for_test ();
  let attempts = ref 0 in
  let filter =
    TP.subscription_filter_of_params
      (listen_params (`Assoc [ ("toolsListChanged", `Bool true) ]))
  in
  let _ =
    Subs.register ~subscription_id:(`Int 1) ~filter
      ~send:(fun _ -> incr attempts; false)
  in
  let note = TP.jsonrpc_notification "notifications/tools/list_changed" in
  Subs.notify_tools_list_changed note;
  Subs.notify_tools_list_changed note;
  Alcotest.(check int) "the failed send is not repeated" 1 !attempts;
  Alcotest.(check int) "and the entry is gone" 0 (Subs.count ());
  Subs.reset_for_test ()

let test_acknowledgement_and_registration_are_atomic () =
  Eio_main.run @@ fun _env ->
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
  Eio.Switch.run @@ fun sw ->
  Subs.reset_for_test ();
  Fun.protect ~finally:Subs.reset_for_test (fun () ->
    let events = ref [] in
    let ack_finished = ref false and premature = ref false in
    let sent, resolve = Eio.Promise.create () in
    let filter = TP.subscription_filter_of_params
      (listen_params (`Assoc [ "toolsListChanged", `Bool true ])) in
    let token = Subs.register_after_ack ~subscription_id:(`Int 1) ~filter
      ~send:(fun _ ->
        if not !ack_finished then premature := true;
        events := "change" :: !events; true)
      ~acknowledge:(fun () ->
        events := "ack" :: !events;
        Eio.Fiber.fork ~sw (fun () ->
          Subs.notify_tools_list_changed
            (TP.jsonrpc_notification "notifications/tools/list_changed");
          Eio.Promise.resolve resolve ());
        Eio.Fiber.yield ();
        ack_finished := true;
        true) in
    Eio.Promise.await sent;
    Alcotest.(check (list string)) "a concurrent change follows the acknowledgement"
      [ "ack"; "change" ] (List.rev !events);
    Alcotest.(check bool) "notification waits until acknowledgement completes" false !premature;
    (match token with Some token -> Subs.unregister token | None -> Alcotest.fail "ack failed");
    let failed = Subs.register_after_ack ~subscription_id:(`Int 2) ~filter
      ~send:(fun _ -> true) ~acknowledge:(fun () -> false) in
    Alcotest.(check bool) "failed acknowledgement leaves no registration" true (failed = None);
    Alcotest.(check int) "registry is empty" 0 (Subs.count ())))

let test_subscription_filter_wire_validation () =
  let accepted = listen_params (`Assoc
    [ "toolsListChanged", `Bool true
    ; "resourceSubscriptions", `List [ `String "masc://status" ] ]) in
  (match TP.validate_subscription_filter_params accepted with
   | Ok filter ->
     Alcotest.(check bool) "requested tools notifications are retained" true filter.tools_list_changed;
     Alcotest.(check (list string)) "resource subscriptions retained"
       [ "masc://status" ] filter.resource_subscriptions
   | Error detail -> Alcotest.fail detail);
  List.iter
    (fun (label, params) ->
      match TP.validate_subscription_filter_params params with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "%s should be rejected" label)
    [ "missing filter", Some (`Assoc [])
    ; "wrong boolean", listen_params (`Assoc [ "toolsListChanged", `String "yes" ])
    ; "non-string URI", listen_params (`Assoc [ "resourceSubscriptions", `List [ `Int 1 ] ])
    ; "duplicate field", listen_params (`Assoc [ "toolsListChanged", `Bool true; "toolsListChanged", `Bool false ]) ]

let test_blocked_ack_does_not_lock_other_subscriptions () =
  Eio_main.run @@ fun env ->
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Subs.reset_for_test ();
  Fun.protect ~finally:Subs.reset_for_test (fun () ->
    let ack_started, start_ack = Eio.Promise.create () in
    let release_ack, release = Eio.Promise.create () in
    let opened, opened_resolver = Eio.Promise.create () in
    let tools = TP.subscription_filter_of_params
      (listen_params (`Assoc [ "toolsListChanged", `Bool true ])) in
    Eio.Fiber.fork ~sw (fun () ->
      let token = Subs.register_after_ack ~subscription_id:(`Int 1) ~filter:tools
        ~send:(fun _ -> true)
        ~acknowledge:(fun () ->
          Eio.Promise.resolve start_ack ();
          Eio.Promise.await release_ack;
          true) in
      Eio.Promise.resolve opened_resolver token);
    Eio.Promise.await ack_started;
    let resources = TP.subscription_filter_of_params
      (listen_params (`Assoc [ "resourceSubscriptions", `List [ `String "masc://status" ] ])) in
    let delivered = ref false in
    let sibling = Subs.register ~subscription_id:(`Int 2) ~filter:resources
      ~send:(fun _ -> delivered := true; true) in
    Subs.notify_resource_updated ~uri:"masc://status"
      (TP.jsonrpc_notification "notifications/resources/updated");
    Alcotest.(check bool) "unrelated subscriber receives while ACK is blocked" true !delivered;
    Eio.Promise.resolve release ();
    (match Eio.Promise.await opened with
     | Some token -> Subs.unregister token
     | None -> Alcotest.fail "acknowledgement unexpectedly failed");
    Subs.unregister sibling))

let test_failed_ack_does_not_poison_publishers () =
  Eio_main.run @@ fun env ->
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Subs.reset_for_test ();
  Fun.protect ~finally:Subs.reset_for_test (fun () ->
    let started, start = Eio.Promise.create () in
    let release, release_resolver = Eio.Promise.create () in
    let ack_done, resolve_ack = Eio.Promise.create () in
    let publish_done, resolve_publish = Eio.Promise.create () in
    let filter = TP.subscription_filter_of_params
      (listen_params (`Assoc [ "toolsListChanged", `Bool true ])) in
    let sibling_count = ref 0 in
    let sibling = Subs.register ~subscription_id:(`Int 2) ~filter
      ~send:(fun _ -> incr sibling_count; true) in
    Eio.Fiber.fork ~sw (fun () ->
      let failed =
        try
          ignore (Subs.register_after_ack ~subscription_id:(`Int 1) ~filter
            ~send:(fun _ -> true)
            ~acknowledge:(fun () ->
              Eio.Promise.resolve start ();
              Eio.Promise.await release;
              failwith "ack write failed") : Subs.token option);
          false
        with Failure _ -> true
      in
      Eio.Promise.resolve resolve_ack failed);
    Eio.Promise.await started;
    Eio.Fiber.fork ~sw (fun () ->
      let outcome =
        try
          Subs.notify_tools_list_changed
            (TP.jsonrpc_notification "notifications/tools/list_changed");
          true
        with _ -> false
      in
      Eio.Promise.resolve resolve_publish outcome);
    Eio.Fiber.yield ();
    Eio.Promise.resolve release_resolver ();
    Alcotest.(check bool) "ACK failure reaches its caller" true (Eio.Promise.await ack_done);
    Alcotest.(check bool) "publisher is not poisoned" true (Eio.Promise.await publish_done);
    Alcotest.(check int) "healthy sibling receives the event" 1 !sibling_count;
    Alcotest.(check int) "failed subscription removed" 1 (Subs.count ());
    Subs.unregister sibling))

let test_cancelled_ack_releases_subscription () =
  Eio_main.run @@ fun env ->
  let was_ready = Eio_guard.is_ready () in
  Eio_guard.enable ();
  Fun.protect ~finally:(fun () -> if not was_ready then Eio_guard.disable ()) (fun () ->
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 @@ fun () ->
  Eio.Switch.run @@ fun sw ->
  Subs.reset_for_test ();
  Fun.protect ~finally:Subs.reset_for_test (fun () ->
    let started, start = Eio.Promise.create () in
    let release, release_ack = Eio.Promise.create () in
    let publish_done, resolve_publish = Eio.Promise.create () in
    let released = ref false in
    let filter = TP.subscription_filter_of_params
      (listen_params (`Assoc [ "toolsListChanged", `Bool true ])) in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      (* A fixture fallback prevents the broken cancellation case from hanging. *)
      Eio.Time.sleep (Eio.Stdenv.clock env) 0.1;
      released := true;
      Eio.Promise.resolve release_ack ();
      `Stop_daemon);
    let result = Eio.Fiber.first
      (fun () ->
        ignore (Subs.register_after_ack ~subscription_id:(`Int 1) ~filter
          ~send:(fun _ -> true)
          ~acknowledge:(fun () ->
            Eio.Promise.resolve start ();
            Eio.Promise.await release;
            true) : Subs.token option);
        `Ack_returned)
      (fun () ->
        Eio.Promise.await started;
        Eio.Fiber.fork ~sw (fun () ->
          Subs.notify_tools_list_changed
            (TP.jsonrpc_notification "notifications/tools/list_changed");
          Eio.Promise.resolve resolve_publish ());
        Eio.Fiber.yield ();
        `Cancel_ack)
    in
    Alcotest.(check bool) "cancellation did not wait for the ACK fallback" false !released;
    Alcotest.(check bool) "cancelling branch won" true (result = `Cancel_ack);
    Eio.Promise.await publish_done;
    Alcotest.(check int) "cancelled subscription removed" 0 (Subs.count ())))

let () =
  run "Mcp_transport_protocol Coverage" [
    "constants", [
      test_case "sse_content_type" `Quick test_sse_content_type;
      test_case "json_content_type" `Quick test_json_content_type;
      test_case "default_protocol_version" `Quick test_default_protocol_version;
      test_case "supported_protocol_versions" `Quick test_supported_protocol_versions;
      test_case "supported_protocol_versions includes 2026 stateless" `Quick
        test_supported_protocol_versions_includes_2026_stateless;
    ];
    "protocol_versions", [
      test_case "from_params none" `Quick test_protocol_version_from_params_none;
      test_case "from_params present" `Quick test_protocol_version_from_params_present;
      test_case "from_body initialize" `Quick test_protocol_version_from_body_initialize;
      test_case "from_body invalid normalizes" `Quick
        test_protocol_version_from_body_invalid_normalizes;
      test_case "initialize only negotiates legacy" `Quick
        test_initialize_does_not_negotiate_a_stateless_version;
      test_case "legacy default keeps a legacy latest" `Quick
        test_legacy_default_keeps_a_legacy_latest;
      test_case "negotiate legacy uses the given counter-offer" `Quick
        test_negotiate_legacy_uses_the_given_counter_offer;
      test_case "legacy default skips a stateless latest" `Quick
        test_legacy_default_skips_a_stateless_latest;
      test_case "legacy default needs a legacy version" `Quick
        test_legacy_default_needs_a_legacy_version;
      test_case "legacy default matches the sdk" `Quick
        test_legacy_default_matches_the_sdk;
      test_case "from_body non_initialize" `Quick
        test_protocol_version_from_body_non_initialize;
      test_case "from_body missing jsonrpc" `Quick
        test_protocol_version_from_body_missing_jsonrpc;
      test_case "from_request_meta_body" `Quick
        test_protocol_version_from_request_meta_body;
      test_case "request protocol admission" `Quick test_request_protocol_admission;
      test_case "null ID is not a notification" `Quick test_request_null_id_is_not_a_notification;
    ];
    "accepts_json", [
      test_case "none" `Quick test_accepts_json_none;
      test_case "exact" `Quick test_accepts_json_exact;
      test_case "not found" `Quick test_accepts_json_not_found;
      test_case "wildcard */*" `Quick test_accepts_json_wildcard;
      test_case "in list" `Quick test_accepts_json_in_list;
      test_case "case-insensitive" `Quick test_accepts_json_case_insensitive;
    ];
    "is_json_content_type", [
      test_case "none" `Quick test_json_content_type_none;
      test_case "exact" `Quick test_json_content_type_exact;
      test_case "with params" `Quick test_json_content_type_with_params;
      test_case "case-insensitive" `Quick test_json_content_type_case_insensitive;
      test_case "rejects jsonp" `Quick test_json_content_type_rejects_jsonp;
      test_case "rejects wildcard" `Quick test_json_content_type_rejects_wildcard;
      test_case "rejects accept list" `Quick
        test_json_content_type_rejects_accept_list;
    ];
    "accepts_sse_header", [
      test_case "none" `Quick test_accepts_sse_none;
      test_case "json only" `Quick test_accepts_sse_json_only;
      test_case "wildcard" `Quick test_accepts_sse_wildcard;
      test_case "exact" `Quick test_accepts_sse_exact;
      test_case "with q" `Quick test_accepts_sse_with_q;
      test_case "q zero" `Quick test_accepts_sse_q_zero;
      test_case "case-insensitive" `Quick test_accepts_sse_case_insensitive;
    ];
    "accepts_streamable_mcp", [
      test_case "none" `Quick test_streamable_none;
      test_case "json only" `Quick test_streamable_json_only;
      test_case "sse only" `Quick test_streamable_sse_only;
      test_case "both" `Quick test_streamable_both;
      test_case "reversed" `Quick test_streamable_both_reversed;
      test_case "json q=0" `Quick test_streamable_json_q_zero;
      test_case "sse q=0" `Quick test_streamable_sse_q_zero;
      test_case "case-insensitive" `Quick test_streamable_case_insensitive;
    ];
    "classify_mcp_accept", [
      test_case "streamable" `Quick test_classify_streamable;
      test_case "rejected" `Quick test_classify_rejected;
      test_case "none rejected" `Quick test_classify_none_rejected;
      test_case "wildcard rejected" `Quick test_classify_wildcard_rejected;
    ];
    "make_response resultType", [
      test_case "adds complete" `Quick test_make_response_adds_complete;
      test_case "keeps input_required" `Quick test_make_response_preserves_existing_result_type;
      test_case "envelope intact" `Quick test_make_response_envelope_intact;
      test_case "every result carries the server identity" `Quick
        test_every_result_carries_the_server_identity;
      test_case "handshake identity has one owner" `Quick
        test_handshake_identity_comes_from_the_same_place;
      test_case "an absent filter subscribes to nothing" `Quick
        test_an_absent_filter_subscribes_to_nothing;
      test_case "the acknowledgement omits what was not asked for" `Quick
        test_the_acknowledged_filter_omits_what_was_not_asked_for;
      test_case "a notification carries the subscription id" `Quick
        test_a_notification_carries_the_subscription_id;
      test_case "acknowledgement and registration are atomic" `Quick
        test_acknowledgement_and_registration_are_atomic;
      test_case "subscription filter wire validation" `Quick
        test_subscription_filter_wire_validation;
      test_case "blocked acknowledgement does not lock other subscriptions" `Quick
        test_blocked_ack_does_not_lock_other_subscriptions;
      test_case "failed acknowledgement does not poison publishers" `Quick
        test_failed_ack_does_not_poison_publishers;
      test_case "cancelled acknowledgement removes the pending subscription" `Quick
        test_cancelled_ack_releases_subscription;
      test_case "a stream receives only what it asked for" `Quick
        test_a_stream_receives_only_what_it_asked_for;
      test_case "a dead stream is retired" `Quick test_a_dead_stream_is_retired;
    ];
  ]
