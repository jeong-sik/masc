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
  check string "default protocol version" "2026-07-28"
    Mcp_transport_protocol.default_protocol_version

let test_supported_protocol_versions () =
  check (list string) "current version only" [ "2026-07-28" ]
    Mcp_transport_protocol.supported_protocol_versions;
  check bool "2026 is stateless" true
    (Mcp_transport_protocol.is_stateless_protocol_version "2026-07-28");
  check bool "draft alias rejected" false
    (Mcp_transport_protocol.is_supported_protocol_version "DRAFT-2026-v1");
  check bool "unknown revision rejected" false
    (Mcp_transport_protocol.is_supported_protocol_version "unsupported-version")

let test_protocol_version_from_request_meta_body () =
  check (option string) "request meta version" (Some "2026-07-28")
    (Mcp_transport_protocol.protocol_version_from_request_meta_body
       {|{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}|})

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

let () =
  run "Mcp_transport_protocol Coverage" [
    "constants", [
      test_case "sse_content_type" `Quick test_sse_content_type;
      test_case "json_content_type" `Quick test_json_content_type;
      test_case "default_protocol_version" `Quick test_default_protocol_version;
      test_case "supported_protocol_versions" `Quick test_supported_protocol_versions;
    ];
    "protocol_versions", [
      test_case "from_request_meta_body" `Quick
        test_protocol_version_from_request_meta_body;
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
  ]
