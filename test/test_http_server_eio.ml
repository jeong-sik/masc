(** Test suite for Http_server_eio module

    Tests the Eio-native HTTP server infrastructure using httpun-eio.
*)

open Masc_mcp.Http_server_eio

(* ===== Unit Tests for Router ===== *)

let test_router_empty () =
  let routes = Router.empty in
  Alcotest.(check int) "empty router" 0 (List.length routes)
;;

let test_router_add_get () =
  let handler _req _reqd = () in
  let routes = Router.empty |> Router.get "/test" handler in
  Alcotest.(check int) "one route" 1 (List.length routes)
;;

let test_router_add_post () =
  let handler _req _reqd = () in
  let routes = Router.empty |> Router.post "/api" handler in
  Alcotest.(check int) "one route" 1 (List.length routes)
;;

let test_router_add_multiple () =
  let handler _req _reqd = () in
  let routes =
    Router.empty
    |> Router.get "/health" handler
    |> Router.post "/api/call" handler
    |> Router.any "/any" handler
  in
  Alcotest.(check int) "three routes" 3 (List.length routes)
;;

let test_router_prefix_specificity () =
  let generic_handler _req _reqd = () in
  let asset_handler _req _reqd = () in
  let routes =
    Router.empty
    |> Router.prefix_get "/dashboard/assets/" asset_handler
    |> Router.prefix_get "/dashboard/" generic_handler
  in
  let request = Httpun.Request.create `GET "/dashboard/assets/index.css" in
  match Router.resolve routes request with
  | `Matched route ->
    Alcotest.(check string)
      "longest prefix route should win"
      "PREFIX:/dashboard/assets/"
      route.path
  | `Method_not_allowed ->
    Alcotest.fail "expected a matched prefix route, got method_not_allowed"
  | `Not_found -> Alcotest.fail "expected a matched prefix route, got not_found"
;;

let test_frontend_transport_routes_present () =
  let routes =
    Masc_mcp.Server_routes_http_routes_frontend.add_routes
      ~port:8935
      ~host:"127.0.0.1"
      Router.empty
  in
  let has_route meth path =
    List.exists
      (fun (route : Router.route) ->
         String.equal route.path path && List.mem meth route.methods)
      routes
  in
  Alcotest.(check bool) "GET /ws route" true (has_route `GET "/ws");
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

let test_frontend_canonical_loopback_location_localhost () =
  let headers = Httpun.Headers.of_list [ "host", "localhost:8935" ] in
  let request = Httpun.Request.create ~headers `GET "/dashboard?agent=codex" in
  let location =
    Masc_mcp.Server_routes_http_routes_frontend.canonical_loopback_location
      ~default_port:8935
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
    Masc_mcp.Server_routes_http_routes_frontend.canonical_loopback_location
      ~default_port:8935
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
    Masc_mcp.Server_routes_http_routes_frontend.canonical_loopback_location
      ~default_port:8935
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
    Masc_mcp.Server_routes_http_routes_frontend.canonical_root_dashboard_location
      ~default_port:8935
      request
  in
  Alcotest.(check (option string))
    "localhost root redirects directly to dashboard"
    (Some "http://127.0.0.1:8935/dashboard")
    location
;;

let test_parse_host_port_rejects_scheme_in_host_header () =
  let parsed =
    Masc_mcp.Server_routes_http_common.parse_host_port
      (Some "http://localhost:8935")
      "127.0.0.1"
      8935
  in
  Alcotest.(check (pair string int))
    "scheme-bearing host header falls back"
    ("127.0.0.1", 8935)
    parsed
;;

let test_parse_host_port_rejects_userinfo_in_host_header () =
  let parsed =
    Masc_mcp.Server_routes_http_common.parse_host_port
      (Some "user@localhost:8935")
      "127.0.0.1"
      8935
  in
  Alcotest.(check (pair string int))
    "userinfo-bearing host header falls back"
    ("127.0.0.1", 8935)
    parsed
;;

(* ===== Unit Tests for Config ===== *)

let test_default_config () =
  Alcotest.(check int) "default port" 8935 default_config.port;
  Alcotest.(check string) "default host" "127.0.0.1" default_config.host;
  Alcotest.(check int) "default max_connections" 128 default_config.max_connections
;;

let test_custom_config () =
  let config = { port = 9000; host = "0.0.0.0"; max_connections = 64 } in
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
  ; "accepts zstd (no header)", `Quick, test_accepts_zstd_no_header
  ]
;;

let router_tests =
  [ "empty router", `Quick, test_router_empty
  ; "add GET route", `Quick, test_router_add_get
  ; "add POST route", `Quick, test_router_add_post
  ; "add multiple routes", `Quick, test_router_add_multiple
  ; "prefix specificity", `Quick, test_router_prefix_specificity
  ; "frontend transport routes present", `Quick, test_frontend_transport_routes_present
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
  ; ( "parse_host_port rejects scheme host header"
    , `Quick
    , test_parse_host_port_rejects_scheme_in_host_header )
  ; ( "parse_host_port rejects userinfo host header"
    , `Quick
    , test_parse_host_port_rejects_userinfo_in_host_header )
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
    ]
;;
