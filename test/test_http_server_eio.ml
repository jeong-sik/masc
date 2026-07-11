(** Test suite for Http_server_eio module

    Tests the Eio-native HTTP server infrastructure using httpun-eio.
*)

open Masc.Http_server_eio

let request_authority_exn request =
  match Server_request_authority.classify_http1_request request with
  | Server_request_authority.Single authority -> authority
  | ( Server_request_authority.Missing
    | Server_request_authority.Multiple
    | Server_request_authority.Malformed ) ->
    Alcotest.fail "expected one valid request authority"
;;

(* ===== Unit Tests for Router ===== *)

let test_router_empty () =
  let routes = Router.create () in
  Alcotest.(check int) "empty router" 0 (Router.route_count routes)
;;

let test_router_add_get () =
  let handler _req _reqd = () in
  let routes = Router.create () |> Router.get "/test" handler in
  Alcotest.(check int) "one route" 1 (Router.route_count routes)
;;

let test_router_add_post () =
  let handler _req _reqd = () in
  let routes = Router.create () |> Router.post "/api" handler in
  Alcotest.(check int) "one route" 1 (Router.route_count routes)
;;

let test_router_add_multiple () =
  let handler _req _reqd = () in
  let routes =
    Router.create ()
    |> Router.get "/health" handler
    |> Router.post "/api/call" handler
    |> Router.any "/any" handler
  in
  Alcotest.(check int) "three routes" 3 (Router.route_count routes)
;;

let test_router_prefix_specificity () =
  let generic_handler _req _reqd = () in
  let asset_handler _req _reqd = () in
  let routes =
    Router.create ()
    |> Router.prefix_get "/dashboard/assets/" asset_handler
    |> Router.prefix_get "/dashboard/" generic_handler
  in
  let request = Httpun.Request.create `GET "/dashboard/assets/index.css" in
  match Router.resolve routes request with
  | `Matched route ->
    Alcotest.(check string)
      "longest prefix route should win"
      "/dashboard/assets/"
      route.path
  | `Method_not_allowed ->
    Alcotest.fail "expected a matched prefix route, got method_not_allowed"
  | `Not_found -> Alcotest.fail "expected a matched prefix route, got not_found"
;;

let test_router_prefix_trie_preserves_specificity () =
  let dashboard_handler _req _reqd = () in
  let board_handler _req _reqd = () in
  let sub_board_handler _req _reqd = () in
  let routes =
    Router.create ()
    |> Router.prefix_get "/dashboard/" dashboard_handler
    |> Router.prefix_get "/api/v1/board/" board_handler
    |> Router.prefix_get "/api/v1/board/sub-boards/" sub_board_handler
  in
  let request = Httpun.Request.create `GET "/api/v1/board/sub-boards/main" in
  match Router.resolve routes request with
  | `Matched route ->
    Alcotest.(check string)
      "longest prefix on the trie path should win"
      "/api/v1/board/sub-boards/"
      route.path
  | `Method_not_allowed ->
    Alcotest.fail "expected trie prefix match, got method_not_allowed"
  | `Not_found -> Alcotest.fail "expected trie prefix match, got not_found"
;;

let test_router_prefix_trie_preserves_root_prefix () =
  let root_handler _req _reqd = () in
  let api_handler _req _reqd = () in
  let routes =
    Router.create ()
    |> Router.prefix_get "/" root_handler
    |> Router.prefix_get "/api/v1/" api_handler
  in
  let request = Httpun.Request.create `GET "/unknown/path" in
  match Router.resolve routes request with
  | `Matched route ->
    Alcotest.(check string) "root prefix remains a fallback" "/" route.path
  | `Method_not_allowed ->
    Alcotest.fail "expected root prefix fallback, got method_not_allowed"
  | `Not_found -> Alcotest.fail "expected root prefix fallback, got not_found"
;;

let test_router_indexed_prefix_fallback_after_exact_method_miss () =
  let exact_handler _req _reqd = () in
  let prefix_handler _req _reqd = () in
  let routes =
    Router.create ()
    |> Router.get "/api/v1/items/42" exact_handler
    |> Router.prefix_post "/api/v1/items/" prefix_handler
  in
  let request = Httpun.Request.create `POST "/api/v1/items/42" in
  match Router.resolve routes request with
  | `Matched route ->
    Alcotest.(check string)
      "indexed router preserves prefix fallback"
      "/api/v1/items/"
      route.path
  | `Method_not_allowed ->
    Alcotest.fail "expected prefix fallback, got method_not_allowed"
  | `Not_found -> Alcotest.fail "expected prefix fallback, got not_found"
;;

let test_router_method_index_preserves_exact_405 () =
  let handler _req _reqd = () in
  let routes = Router.create () |> Router.get "/api/v1/exact-only" handler in
  let request = Httpun.Request.create `POST "/api/v1/exact-only" in
  match Router.resolve routes request with
  | `Method_not_allowed -> ()
  | `Matched route ->
    Alcotest.failf "expected method_not_allowed, got matched route %s" route.path
  | `Not_found -> Alcotest.fail "expected method_not_allowed, got not_found"
;;

let test_frontend_transport_routes_present () =
  let routes =
    Server_routes_http_routes_frontend.add_routes
      ~port:8935
      (Router.create ())
  in
  let has_route meth path =
    List.exists
      (fun (route : Router.route) ->
         String.equal route.path path && List.mem meth route.methods)
      (Router.routes routes)
  in
  Alcotest.(check bool) "GET /ws route" true (has_route `GET "/ws");
  (* RFC-0281: /ws must be a typed WebSocket-upgrade route ([Router.Ws]),
     not a plain route.  Only a Ws route receives the Gluten [upgrade]
     capability and thus actually drives the post-101 connection.  A
     regression to [Router.Plain] (or to a main_eio special-case that
     bypasses the router) silently reintroduces the undriven-socket
     flicker bug — this assertion guards the consolidation. *)
  (match Router.resolve routes (Httpun.Request.create `GET "/ws") with
   | `Matched route ->
     (match route.handler with
      | Router.Ws _ -> ()
      | Router.Plain _ -> Alcotest.fail "/ws must be a Router.Ws route, not Plain")
   | `Method_not_allowed | `Not_found -> Alcotest.fail "/ws route must resolve");
  Alcotest.(check bool)
    "GET /api/v1/voice/config route"
    true
    (has_route `GET "/api/v1/voice/config");
  Alcotest.(check bool) "POST /webrtc/offer route" true (has_route `POST "/webrtc/offer");
  Alcotest.(check bool)
    "POST /webrtc/answer route"
    true
    (has_route `POST "/webrtc/answer")
;;

(* RFC-0281: typed WebSocket-upgrade routes.  [ws_get] registers a
   [Router.Ws] route (carrying the Gluten upgrade capability); [get]
   registers a [Router.Plain] route.  The variant is what lets
   [Router.dispatch] thread [upgrade] to WS routes and reject WS routes
   on non-upgrade transports with 426. *)
let test_router_ws_get_registers_ws_route () =
  let handler ~upgrade:_ _req _reqd = () in
  let routes = Router.create () |> Router.ws_get "/ws" handler in
  match Router.resolve routes (Httpun.Request.create `GET "/ws") with
  | `Matched route ->
    (match route.handler with
     | Router.Ws _ -> ()
     | Router.Plain _ -> Alcotest.fail "ws_get must register a Router.Ws route")
  | `Method_not_allowed | `Not_found -> Alcotest.fail "ws_get route must resolve"
;;

let test_router_get_registers_plain_route () =
  let handler _req _reqd = () in
  let routes = Router.create () |> Router.get "/plain" handler in
  match Router.resolve routes (Httpun.Request.create `GET "/plain") with
  | `Matched route ->
    (match route.handler with
     | Router.Plain _ -> ()
     | Router.Ws _ -> Alcotest.fail "get must register a Router.Plain route")
  | `Method_not_allowed | `Not_found -> Alcotest.fail "get route must resolve"
;;

let with_env name value_opt f =
  let original = Sys.getenv_opt name in
  let restore () =
    match original with
    | Some value -> Unix.putenv name value
    | None -> Unix.putenv name ""
  in
  Fun.protect
    ~finally:restore
    (fun () ->
       (match value_opt with
        | Some value -> Unix.putenv name value
        | None -> Unix.putenv name "");
       f ())
;;

let with_ws_same_origin_ready ready f =
  Masc.Transport_metrics.set_ws_same_origin_runtime_ready ready;
  Fun.protect
    ~finally:(fun () ->
      Masc.Transport_metrics.set_ws_same_origin_runtime_ready false)
    f
;;

let test_frontend_websocket_upgrade_waits_for_dispatcher () =
  with_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    with_ws_same_origin_ready false (fun () ->
      Alcotest.(check (option string))
        "dispatcher-not-ready upgrades are rejected"
        (Some "WebSocket transport not ready")
        (Server_routes_http_routes_frontend.websocket_upgrade_unavailable_reason ())))
;;

let test_frontend_websocket_upgrade_allows_ready_dispatcher () =
  with_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    with_ws_same_origin_ready true (fun () ->
      Alcotest.(check (option string))
        "ready dispatcher admits upgrades"
        None
        (Server_routes_http_routes_frontend.websocket_upgrade_unavailable_reason ())))
;;

let test_voice_routes_present () =
  let routes = Server_routes_http_routes_voice.add_routes (Router.create ()) in
  let has_route meth path =
    List.exists
      (fun (route : Router.route) ->
         String.equal route.path path && List.mem meth route.methods)
      (Router.routes routes)
  in
  Alcotest.(check bool)
    "GET /api/v1/voice/audio/ capability route"
    true
    (has_route `GET "/api/v1/voice/audio/");
  Alcotest.(check bool)
    "POST /api/v1/voice/transcribe route"
    true
    (has_route `POST "/api/v1/voice/transcribe")
;;

let test_frontend_canonical_loopback_location_localhost () =
  let headers = Httpun.Headers.of_list [ "host", "localhost:8935" ] in
  let request = Httpun.Request.create ~headers `GET "/dashboard?agent=codex" in
  let location =
    Server_routes_http_routes_frontend.canonical_loopback_location
      ~default_port:8935
      ~request_authority:(request_authority_exn request)
      request
  in
  Alcotest.(check (option string))
    "localhost redirects to canonical loopback"
    (Some "http://127.0.0.1:8935/dashboard?agent=codex")
    location
;;

let test_frontend_canonical_loopback_location_ipv6 () =
  let headers = Httpun.Headers.of_list [ "host", "[::1]:8935" ] in
  let request = Httpun.Request.create ~headers `GET "/dashboard" in
  let location =
    Server_routes_http_routes_frontend.canonical_loopback_location
      ~default_port:8935
      ~request_authority:(request_authority_exn request)
      request
  in
  Alcotest.(check (option string))
    "::1 redirects to canonical loopback"
    (Some "http://127.0.0.1:8935/dashboard")
    location
;;

let test_frontend_canonical_loopback_location_canonical_host () =
  let headers = Httpun.Headers.of_list [ "host", "127.0.0.1:8935" ] in
  let request = Httpun.Request.create ~headers `GET "/dashboard" in
  let location =
    Server_routes_http_routes_frontend.canonical_loopback_location
      ~default_port:8935
      ~request_authority:(request_authority_exn request)
      request
  in
  Alcotest.(check (option string))
    "canonical loopback host does not redirect"
    None
    location
;;

let test_frontend_canonical_root_dashboard_location_localhost () =
  let headers = Httpun.Headers.of_list [ "host", "localhost:8935" ] in
  let request = Httpun.Request.create ~headers `GET "/" in
  let location =
    Server_routes_http_routes_frontend.canonical_root_dashboard_location
      ~default_port:8935
      ~request_authority:(request_authority_exn request)
  in
  Alcotest.(check (option string))
    "localhost root redirects directly to dashboard"
    (Some "http://127.0.0.1:8935/dashboard")
    location
;;

(* ===== Unit Tests for Config ===== *)

let test_default_config () =
  Alcotest.(check int) "default port" 8935 default_config.port;
  Alcotest.(check string) "default host" "127.0.0.1" default_config.host;
  Alcotest.(check int) "default max_connections" 512 default_config.max_connections
;;

let test_custom_config () =
  let config =
    { port = 9000; host = "0.0.0.0"; max_connections = 64; listen_backlog = 32 }
  in
  Alcotest.(check int) "custom port" 9000 config.port;
  Alcotest.(check string) "custom host" "0.0.0.0" config.host
;;

(* ===== Unit Tests for Request helpers ===== *)

let test_request_path_simple () =
  let request = Httpun.Request.create `GET "/health" in
  Alcotest.(check string) "simple path" "/health" (Request.path request)
;;

let test_request_path_with_query () =
  let request = Httpun.Request.create `GET "/api?key=value" in
  Alcotest.(check string) "path without query" "/api" (Request.path request)
;;

let test_request_method () =
  let get_req = Httpun.Request.create `GET "/" in
  let post_req = Httpun.Request.create `POST "/" in
  Alcotest.(check bool) "GET method" true (Request.method_ get_req = `GET);
  Alcotest.(check bool) "POST method" true (Request.method_ post_req = `POST)
;;

let test_request_header () =
  let headers = Httpun.Headers.of_list [ "content-type", "application/json" ] in
  let request = Httpun.Request.create ~headers `GET "/" in
  Alcotest.(check (option string))
    "header found"
    (Some "application/json")
    (Request.header request "content-type");
  Alcotest.(check (option string))
    "header not found"
    None
    (Request.header request "x-custom")
;;

let test_response_content_headers_preserve_all_segments () =
  let headers =
    Response.content_headers
      ~before_headers:[ "vary", "accept-encoding" ]
      ~after_headers:[ "etag", "\"abc\"" ]
      ~tail_headers:[ "content-encoding", "zstd" ]
      ~content_type:Response.json_content_type
      "{}"
  in
  Alcotest.(check (list (pair string string)))
    "header order"
    [ "vary", "accept-encoding"
    ; "content-type", Response.json_content_type
    ; "content-length", "2"
    ; "etag", "\"abc\""
    ; "content-encoding", "zstd"
    ]
    (Httpun.Headers.to_list headers);
  Alcotest.(check (option string))
    "before header"
    (Some "accept-encoding")
    (Httpun.Headers.get headers "vary");
  Alcotest.(check (option string))
    "content-type"
    (Some Response.json_content_type)
    (Httpun.Headers.get headers "content-type");
  Alcotest.(check (option string))
    "content-length"
    (Some "2")
    (Httpun.Headers.get headers "content-length");
  Alcotest.(check (option string))
    "after header"
    (Some "\"abc\"")
    (Httpun.Headers.get headers "etag");
  Alcotest.(check (option string))
    "tail header"
    (Some "zstd")
    (Httpun.Headers.get headers "content-encoding")
;;

(* ===== Unit Tests for Compression (Compact Protocol v4) ===== *)

let test_compression_skip_small () =
  let small_data = "Hello, World!" in
  (* 13 bytes, below 256 threshold *)
  let result, compressed = Compression.compress_zstd small_data in
  Alcotest.(check bool) "small data not compressed" false compressed;
  Alcotest.(check string) "data unchanged" small_data result
;;

let test_compression_large_data () =
  let large_data = String.make 1000 'x' in
  (* 1000 bytes of 'x' - highly compressible *)
  let result, compressed = Compression.compress_zstd large_data in
  Alcotest.(check bool) "large data compressed" true compressed;
  Alcotest.(check bool)
    "result smaller"
    true
    (String.length result < String.length large_data)
;;

let test_compression_roundtrip () =
  (* Use highly repetitive data that will definitely compress *)
  let original = String.make 500 'A' ^ String.make 500 'B' ^ String.make 500 'C' in
  let compressed_data, did_compress = Compression.compress_zstd original in
  Alcotest.(check bool) "data should compress" true did_compress;
  let decompressed = Zstd.decompress (String.length original) compressed_data in
  Alcotest.(check string) "roundtrip preserves data" original decompressed
;;

let test_accepts_zstd_positive () =
  let headers = Httpun.Headers.of_list [ "accept-encoding", "gzip, deflate, zstd" ] in
  let request = Httpun.Request.create ~headers `GET "/" in
  Alcotest.(check bool) "accepts zstd" true (Compression.accepts_zstd request)
;;

let test_accepts_zstd_only_zstd () =
  let headers = Httpun.Headers.of_list [ "accept-encoding", "zstd" ] in
  let request = Httpun.Request.create ~headers `GET "/" in
  Alcotest.(check bool) "accepts zstd only" true (Compression.accepts_zstd request)
;;

let test_accepts_zstd_negative () =
  let headers = Httpun.Headers.of_list [ "accept-encoding", "gzip, deflate, br" ] in
  let request = Httpun.Request.create ~headers `GET "/" in
  Alcotest.(check bool) "no zstd" false (Compression.accepts_zstd request)
;;

let test_accepts_zstd_rejects_q_zero () =
  let headers =
    Httpun.Headers.of_list [ "accept-encoding", "gzip, zstd;q=0, br" ]
  in
  let request = Httpun.Request.create ~headers `GET "/" in
  Alcotest.(check bool) "zstd q=0 rejected" false (Compression.accepts_zstd request)
;;

let test_accepts_zstd_dict_positive () =
  let headers =
    Httpun.Headers.of_list [ "accept-encoding", "gzip, zstd; dict=masc" ]
  in
  let request = Httpun.Request.create ~headers `GET "/" in
  Alcotest.(check bool)
    "zstd dictionary accepted"
    true
    (Compression.accepts_zstd_dict request)
;;

let test_accepts_zstd_dict_rejects_q_zero () =
  let headers =
    Httpun.Headers.of_list [ "accept-encoding", "zstd; dict=masc; q=0" ]
  in
  let request = Httpun.Request.create ~headers `GET "/" in
  Alcotest.(check bool)
    "zstd dictionary q=0 rejected"
    false
    (Compression.accepts_zstd_dict request)
;;

let test_accepts_zstd_no_header () =
  let request = Httpun.Request.create `GET "/" in
  Alcotest.(check bool) "no header" false (Compression.accepts_zstd request)
;;

(* ===== Test Suites ===== *)

let compression_tests =
  [ "skip small data", `Quick, test_compression_skip_small
  ; "compress large data", `Quick, test_compression_large_data
  ; "roundtrip", `Quick, test_compression_roundtrip
  ; "accepts zstd (positive)", `Quick, test_accepts_zstd_positive
  ; "accepts zstd (only)", `Quick, test_accepts_zstd_only_zstd
  ; "accepts zstd (negative)", `Quick, test_accepts_zstd_negative
  ; "accepts zstd rejects q=0", `Quick, test_accepts_zstd_rejects_q_zero
  ; "accepts zstd-dict positive", `Quick, test_accepts_zstd_dict_positive
  ; "accepts zstd-dict rejects q=0", `Quick, test_accepts_zstd_dict_rejects_q_zero
  ; "accepts zstd (no header)", `Quick, test_accepts_zstd_no_header
  ]
;;

let router_tests =
  [ "empty router", `Quick, test_router_empty
  ; "add GET route", `Quick, test_router_add_get
  ; "add POST route", `Quick, test_router_add_post
  ; "add multiple routes", `Quick, test_router_add_multiple
  ; "prefix specificity", `Quick, test_router_prefix_specificity
  ; ( "prefix trie preserves specificity"
    , `Quick
    , test_router_prefix_trie_preserves_specificity )
  ; ( "prefix trie preserves root prefix"
    , `Quick
    , test_router_prefix_trie_preserves_root_prefix )
  ; ( "indexed prefix fallback after exact method miss"
    , `Quick
    , test_router_indexed_prefix_fallback_after_exact_method_miss )
  ; ( "method index preserves exact 405"
    , `Quick
    , test_router_method_index_preserves_exact_405 )
  ; "frontend transport routes present", `Quick, test_frontend_transport_routes_present
  ; "ws_get registers a Ws route", `Quick, test_router_ws_get_registers_ws_route
  ; "get registers a Plain route", `Quick, test_router_get_registers_plain_route
  ; ( "frontend websocket upgrade waits for dispatcher"
    , `Quick
    , test_frontend_websocket_upgrade_waits_for_dispatcher )
  ; ( "frontend websocket upgrade allows ready dispatcher"
    , `Quick
    , test_frontend_websocket_upgrade_allows_ready_dispatcher )
  ; "voice routes present", `Quick, test_voice_routes_present
  ; ( "frontend canonical localhost redirect"
    , `Quick
    , test_frontend_canonical_loopback_location_localhost )
  ; ( "frontend canonical ipv6 redirect"
    , `Quick
    , test_frontend_canonical_loopback_location_ipv6 )
  ; ( "frontend canonical host stays put"
    , `Quick
    , test_frontend_canonical_loopback_location_canonical_host )
  ; ( "frontend canonical root goes direct to dashboard"
    , `Quick
    , test_frontend_canonical_root_dashboard_location_localhost )
  ]
;;

let config_tests =
  [ "default config", `Quick, test_default_config
  ; "custom config", `Quick, test_custom_config
  ]
;;

let request_tests =
  [ "path simple", `Quick, test_request_path_simple
  ; "path with query", `Quick, test_request_path_with_query
  ; "method", `Quick, test_request_method
  ; "header", `Quick, test_request_header
  ]
;;

(* RFC 7230 §3.3.2: a 204 response with no payload should still carry
   an explicit [Content-Length: 0] so keep-alive clients and proxies
   know the body is empty. *)
let contains_substring haystack needle =
  let hlen = String.length haystack in
  let nlen = String.length needle in
  let rec scan i =
    if i + nlen > hlen then false
    else if String.equal (String.sub haystack i nlen) needle then true
    else scan (i + 1)
  in
  nlen = 0 || scan 0
;;

let test_response_empty_includes_content_length_zero () =
  let reqd_ref = ref None in
  let conn =
    Httpun.Server_connection.create (fun reqd -> reqd_ref := Some reqd)
  in
  let request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" in
  let len = String.length request in
  let bs = Bigstringaf.of_string request ~off:0 ~len in
  ignore (Httpun.Server_connection.read conn bs ~off:0 ~len);
  let reqd = Option.get !reqd_ref in
  Response.empty reqd;
  let response =
    match Httpun.Server_connection.next_write_operation conn with
    | `Write iovecs ->
      String.concat
        ""
        (List.map
           (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len)
           iovecs)
    | `Yield | `Close _ -> ""
  in
  Alcotest.(check bool)
    "204 Response.empty includes Content-Length: 0"
    true
    (contains_substring response "content-length: 0")
;;

let response_tests =
  [ ( "content_headers preserve all header segments"
    , `Quick
    , test_response_content_headers_preserve_all_segments )
  ; ( "empty response includes Content-Length: 0"
    , `Quick
    , test_response_empty_includes_content_length_zero )
  ]
;;

(* ===== Late_response classifier (#13059) ===== *)

(* Behavioural regression for the cancellation-vs-late-write race.
   Before #13059 a top-level handler [exception] arm caught
   [Eio.Cancel.Cancelled] and converted it into a 500 — that 500
   write itself would fail because the underlying writer was already
   in "invalid state" / "closed", and the *secondary* failure shadowed
   the original cancellation.  The fix re-raises [Cancelled] and
   downgrades the two well-known late-response failure shapes to a
   warning.  The classifier below is the SSOT for "what counts as a
   recognised late-response failure" — these tests pin its truth
   table so a future refactor cannot silently widen or narrow it. *)

let test_late_response_classifies_invalid_state_failure () =
  let exn =
    Failure "httpun.Reqd.respond_with_string: invalid state, response already written"
  in
  match Late_response.classify_write_failure exn with
  | Some msg ->
    Alcotest.(check bool) "preserves the original message" true (String.length msg > 0);
    Alcotest.(check bool)
      "message is the failure payload"
      true
      (String.starts_with msg ~prefix:"httpun.Reqd.respond_with_string: invalid state")
  | None -> Alcotest.fail "expected Some _ for httpun invalid state failure"
;;

let test_late_response_classifies_closed_writer_failure () =
  match
    Late_response.classify_write_failure (Failure "cannot write to closed writer")
  with
  | Some msg ->
    Alcotest.(check string)
      "stable closed-writer label"
      "cannot write to closed writer"
      msg
  | None -> Alcotest.fail "expected Some _ for closed-writer failure"
;;

let test_late_response_does_not_classify_cancellation () =
  (* Cancellation MUST NOT be classified as a late-response failure —
     callers re-raise [Cancelled] before invoking the classifier so
     that the cancellation propagates out of the request handler. *)
  let cancelled = Eio.Cancel.Cancelled (Failure "test cancellation") in
  Alcotest.(check (option string))
    "Cancelled is not a late-response failure"
    None
    (Late_response.classify_write_failure cancelled)
;;

let test_late_response_ignores_unrelated_failures () =
  let cases =
    [ "Failure with unrelated message", Failure "boom"
    ; "Failure with empty message", Failure ""
    ; "Not_found", Not_found
    ; "Division_by_zero", Division_by_zero
    ; ( "Failure mentioning httpun without invalid state prefix"
      , Failure "httpun.Reqd: nothing to do" )
    ]
  in
  List.iter
    (fun (label, exn) ->
       Alcotest.(check (option string))
         label
         None
         (Late_response.classify_write_failure exn))
    cases
;;

let late_response_tests =
  [ ( "invalid state failure -> Some msg"
    , `Quick
    , test_late_response_classifies_invalid_state_failure )
  ; ( "closed writer failure -> Some 'cannot write to closed writer'"
    , `Quick
    , test_late_response_classifies_closed_writer_failure )
  ; ( "Eio.Cancel.Cancelled -> None (caller re-raises)"
    , `Quick
    , test_late_response_does_not_classify_cancellation )
  ; "unrelated exceptions -> None", `Quick, test_late_response_ignores_unrelated_failures
  ]
;;

let () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  Eio_guard.enable ();
  Alcotest.run
    "Http_server_eio"
    [ "compression", compression_tests
    ; (* Compact Protocol v4 *)
      "router", router_tests
    ; "config", config_tests
    ; "request", request_tests
    ; "response", response_tests
    ; "late_response", late_response_tests
    ]
;;
