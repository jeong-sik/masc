(** Test suite for Http_server_eio module

    Tests the Eio-native HTTP server infrastructure using httpun-eio.
*)

open Masc.Http_server_eio

let request_trust_policy =
  match
    Server_request_authority.make_trust_policy
      ~bind_host:"127.0.0.1"
      ~bind_port:8935
      ~explicit_base_url:None
  with
  | Ok policy -> policy
  | Error error ->
    Alcotest.fail (Server_request_authority.trust_policy_error_to_string error)
;;

let request_authority_exn request =
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
  List.iter
    (fun meth ->
       Alcotest.(check bool)
         "operator MCP route"
         true
         (has_route meth "/mcp/operator"))
    [ `GET; `POST; `DELETE ];
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
    (has_route `GET "/api/v1/voice/config")
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

(* A browser's <audio> element cannot put a bearer token in its request
   headers, so the unguessable filename token is the capability. That only
   works while the route registered above is one [Server_auth] answers without
   one. The two used to spell the prefix independently in different files.

   Spelled as a literal here on purpose. Together with the route assertion
   above it makes two independent witnesses that the wire path is the one the
   browser asks for; reading it from the shared constant would let a rename
   move both and prove nothing. *)
let test_the_voice_clip_route_needs_no_bearer_token () =
  Alcotest.(check bool)
    "the clip route is on the public-read list"
    true
    (Server_auth.is_public_read_path "/api/v1/voice/audio/abc123");
  Alcotest.(check bool)
    "a sibling voice route still needs a token"
    false
    (Server_auth.is_public_read_path "/api/v1/voice/config")
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

(* ===== Test Suites ===== *)

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
  ; ( "the voice clip route needs no bearer token"
    , `Quick
    , test_the_voice_clip_route_needs_no_bearer_token )
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
    (String_util.contains_substring response "content-length: 0")
;;

(* ===== JSON conditional-request rule ===== *)

(* [Response.json] offers a validator so a polling client can be told "still
   the same" instead of being sent the body again. Measured on the live
   server, 11 of 12 polled dashboard routes return byte-identical bodies
   across repeated polls, ~1.86 MB per full cycle.

   The rule is exercised here rather than through a live server because what
   can go wrong is the decision, not the socket write: tagging a response that
   must not be reused, or answering 304 to a client that never claimed to hold
   the body. *)

let conditional_body = {|{"keepers":[],"generated_at":1.0}|}

let tag_of body =
  match
    Response.json_conditional ~status:`OK ~meth:`GET ~if_none_match:None ~body
  with
  | Response.Tagged etag -> etag
  | Response.Untagged -> Alcotest.fail "a 200 GET should carry a tag"
  | Response.Not_modified _ ->
    Alcotest.fail "no If-None-Match cannot be a match"

let outcome_label = function
  | Response.Untagged -> "untagged"
  | Response.Tagged _ -> "tagged"
  | Response.Not_modified _ -> "not_modified"

let check_outcome name expected actual =
  Alcotest.(check string) name expected (outcome_label actual)

let test_json_conditional_matching_tag_is_not_modified () =
  let etag = tag_of conditional_body in
  check_outcome
    "a client presenting the current tag is told nothing changed"
    "not_modified"
    (Response.json_conditional ~status:`OK ~meth:`GET
       ~if_none_match:(Some etag) ~body:conditional_body)

let test_json_conditional_stale_tag_sends_the_body () =
  let stale = tag_of {|{"keepers":[],"generated_at":0.0}|} in
  check_outcome
    "a tag from an older body does not suppress the new one"
    "tagged"
    (Response.json_conditional ~status:`OK ~meth:`GET
       ~if_none_match:(Some stale) ~body:conditional_body)

let test_json_conditional_absent_header_sends_the_body () =
  check_outcome
    "a client that claims no copy always receives the body"
    "tagged"
    (Response.json_conditional ~status:`OK ~meth:`GET ~if_none_match:None
       ~body:conditional_body)

(* A tag on an error would invite a client to revalidate it and be told the
   failure is unchanged, so failures carry none — even if the client happens
   to present a matching tag. *)
let test_json_conditional_error_status_carries_no_tag () =
  let etag = tag_of conditional_body in
  List.iter
    (fun status ->
      check_outcome
        "an unsuccessful response carries no validator"
        "untagged"
        (Response.json_conditional ~status ~meth:`GET
           ~if_none_match:(Some etag) ~body:conditional_body))
    [ `Bad_request; `Not_found; `Internal_server_error; `Accepted ]

(* Mutations answer with the result of the mutation. Tagging one would let a
   client be told its stale copy still stands after it changed something. *)
let test_json_conditional_unsafe_method_carries_no_tag () =
  let etag = tag_of conditional_body in
  List.iter
    (fun meth ->
      check_outcome
        "an unsafe method carries no validator"
        "untagged"
        (Response.json_conditional ~status:`OK ~meth
           ~if_none_match:(Some etag) ~body:conditional_body))
    [ `POST; `PUT; `DELETE ]

let test_json_conditional_tag_is_weak_and_body_derived () =
  let etag = tag_of conditional_body in
  Alcotest.(check bool)
    "the tag is weak, because one payload goes out under several encodings"
    true
    (String.starts_with ~prefix:"W/\"" etag);
  Alcotest.(check bool)
    "a different body produces a different tag"
    false
    (String.equal etag (tag_of {|{"keepers":[],"generated_at":2.0}|}));
  Alcotest.(check string)
    "the same body produces the same tag"
    etag
    (tag_of conditional_body)

(* [json_conditional] is a pure function, which is what lets the cases above
   cover every combination of method, status, and If-None-Match. It also means
   none of them touches a response, so the step that turns a [Tagged] decision
   into bytes stayed unverified: whether the validator headers reach the client
   at all, and whether a matching tag produces a bodiless 304.

   A client cannot revalidate on a decision it never sees, so that step is
   exercised here against a real [Server_connection] rather than inferred from
   the branch that builds it. *)

let serve_json_over_wire ?if_none_match body =
  Eio_main.run (fun _env ->
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Response.json ~request:(Httpun.Reqd.request reqd) body reqd)
    in
    let headers =
      let base = [ ("host", "127.0.0.1") ] in
      match if_none_match with
      | None -> base
      | Some tag -> ("if-none-match", tag) :: base
    in
    let request =
      Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET "/probe"
    in
    let request_head =
      Printf.sprintf
        "%s %s HTTP/1.1\r\n%s"
        (Httpun.Method.to_string request.Httpun.Request.meth)
        request.Httpun.Request.target
        (Httpun.Headers.to_string request.Httpun.Request.headers)
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_head) request_head
    in
    let rec feed off =
      let remaining = Bigstringaf.length bytes - off in
      if remaining > 0
      then (
        let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
        if consumed <= 0 then Alcotest.fail "httpun test feed made no progress";
        feed (off + consumed))
    in
    feed 0;
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        List.iter
          (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               response_buf
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
          iovecs;
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Buffer.contents response_buf)
;;

let response_header response name =
  let field = String.lowercase_ascii name ^ ":" in
  String.split_on_char '\n' response
  |> List.filter_map (fun line ->
       let line = String.trim line in
       if String.starts_with ~prefix:field (String.lowercase_ascii line)
       then
         Some
           (String.trim
              (String.sub
                 line
                 (String.length field)
                 (String.length line - String.length field)))
       else None)
  |> function
  | value :: _ -> Some value
  | [] -> None
;;

let response_status_line response =
  match String.index_opt response '\r' with
  | Some idx -> String.sub response 0 idx
  | None -> response
;;

let test_json_response_puts_the_validator_on_the_wire () =
  let response = serve_json_over_wire conditional_body in
  Alcotest.(check string)
    "a plain read is answered in full"
    "HTTP/1.1 200 OK"
    (response_status_line response);
  Alcotest.(check (option string))
    "the client receives the tag it must present to revalidate"
    (Some (tag_of conditional_body))
    (response_header response "etag");
  Alcotest.(check (option string))
    "and is told to revalidate rather than invent a freshness window"
    (Some "no-cache")
    (response_header response "cache-control")
;;

let test_json_response_matching_tag_sends_no_body () =
  let response =
    serve_json_over_wire ~if_none_match:(tag_of conditional_body) conditional_body
  in
  Alcotest.(check string)
    "a client holding the current body is told so"
    "HTTP/1.1 304 Not Modified"
    (response_status_line response);
  Alcotest.(check (option string))
    "with nothing to read"
    (Some "0")
    (response_header response "content-length");
  Alcotest.(check bool)
    "and the body itself never reaches the socket"
    false
    (List.exists
       (fun line -> String.equal (String.trim line) conditional_body)
       (String.split_on_char '\n' response))
;;

let test_json_lazy_matching_tag_skips_body_evaluation () =
  Eio_main.run (fun _env ->
    let response_buf = Buffer.create 1024 in
    let body_called = ref false in
    let test_body = "{\"lazy\":\"evaluated\"}" in
    let etag = Response.weak_etag_value test_body in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Response.json_lazy
          ~request:(Httpun.Reqd.request reqd)
          ~etag
          (fun () -> body_called := true; test_body)
          reqd)
    in
    let headers = [ ("host", "127.0.0.1"); ("if-none-match", etag) ] in
    let request =
      Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET "/lazy-probe"
    in
    let request_head =
      Printf.sprintf
        "%s %s HTTP/1.1\r\n%s"
        (Httpun.Method.to_string request.Httpun.Request.meth)
        request.Httpun.Request.target
        (Httpun.Headers.to_string request.Httpun.Request.headers)
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_head) request_head
    in
    let rec feed off =
      let remaining = Bigstringaf.length bytes - off in
      if remaining > 0
      then (
        let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
        if consumed <= 0 then Alcotest.fail "httpun test feed made no progress";
        feed (off + consumed))
    in
    feed 0;
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        List.iter
          (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               response_buf
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
          iovecs;
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    let response = Buffer.contents response_buf in
    Alcotest.(check string)
      "status is 304 Not Modified"
      "HTTP/1.1 304 Not Modified"
      (response_status_line response);
    Alcotest.(check bool)
      "lazy body generator closure was NEVER called"
      false
      !body_called;
    Alcotest.(check (option string))
      "etag matches in 304 response"
      (Some etag)
      (response_header response "etag"))
;;

let test_json_lazy_unmatched_tag_evaluates_body () =
  Eio_main.run (fun _env ->
    let response_buf = Buffer.create 1024 in
    let body_called = ref false in
    let test_body = "{\"lazy\":\"evaluated\"}" in
    let etag = Response.weak_etag_value test_body in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Response.json_lazy
          ~request:(Httpun.Reqd.request reqd)
          ~etag
          (fun () -> body_called := true; test_body)
          reqd)
    in
    let headers = [ ("host", "127.0.0.1"); ("if-none-match", "W/\"mismatched\"") ] in
    let request =
      Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET "/lazy-probe"
    in
    let request_head =
      Printf.sprintf
        "%s %s HTTP/1.1\r\n%s"
        (Httpun.Method.to_string request.Httpun.Request.meth)
        request.Httpun.Request.target
        (Httpun.Headers.to_string request.Httpun.Request.headers)
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_head) request_head
    in
    let rec feed off =
      let remaining = Bigstringaf.length bytes - off in
      if remaining > 0
      then (
        let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
        if consumed <= 0 then Alcotest.fail "httpun test feed made no progress";
        feed (off + consumed))
    in
    feed 0;
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        List.iter
          (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               response_buf
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
          iovecs;
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    let response = Buffer.contents response_buf in
    Alcotest.(check string)
      "status is 200 OK"
      "HTTP/1.1 200 OK"
      (response_status_line response);
    Alcotest.(check bool)
      "lazy body generator closure was called on miss"
      true
      !body_called;
    Alcotest.(check (option string))
      "etag is returned"
      (Some etag)
      (response_header response "etag"))
;;

let test_json_lazy_preserves_extra_headers_and_matches_wildcard () =
  Eio_main.run (fun _env ->
    let response_buf = Buffer.create 1024 in
    let body_called = ref false in
    let test_body = "{\"lazy\":\"evaluated\"}" in
    let etag = Response.weak_etag_value test_body in
    let extra_headers = [ ("access-control-allow-origin", "*"); ("x-custom", "preserved") ] in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Response.json_lazy
          ~extra_headers
          ~request:(Httpun.Reqd.request reqd)
          ~etag
          (fun () -> body_called := true; test_body)
          reqd)
    in
    let headers = [ ("host", "127.0.0.1"); ("if-none-match", Printf.sprintf "W/\"old\", %s, W/\"other\"" etag) ] in
    let request =
      Httpun.Request.create ~headers:(Httpun.Headers.of_list headers) `GET "/lazy-probe"
    in
    let request_head =
      Printf.sprintf
        "%s %s HTTP/1.1\r\n%s"
        (Httpun.Method.to_string request.Httpun.Request.meth)
        request.Httpun.Request.target
        (Httpun.Headers.to_string request.Httpun.Request.headers)
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_head) request_head
    in
    let rec feed off =
      let remaining = Bigstringaf.length bytes - off in
      if remaining > 0
      then (
        let consumed = Httpun.Server_connection.read conn bytes ~off ~len:remaining in
        if consumed <= 0 then Alcotest.fail "httpun test feed made no progress";
        feed (off + consumed))
    in
    feed 0;
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        List.iter
          (fun (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               response_buf
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len))
          iovecs;
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) -> total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    let response = Buffer.contents response_buf in
    Alcotest.(check string)
      "status is 304 Not Modified"
      "HTTP/1.1 304 Not Modified"
      (response_status_line response);
    Alcotest.(check bool)
      "lazy body generator closure was NEVER called"
      false
      !body_called;
    Alcotest.(check (option string))
      "access-control-allow-origin header preserved on 304"
      (Some "*")
      (response_header response "access-control-allow-origin");
    Alcotest.(check (option string))
      "x-custom header preserved on 304"
      (Some "preserved")
      (response_header response "x-custom"))
;;

let response_tests =
  [ ( "content_headers preserve all header segments"
    , `Quick
    , test_response_content_headers_preserve_all_segments )
  ; ( "empty response includes Content-Length: 0"
    , `Quick
    , test_response_empty_includes_content_length_zero )
  ; ( "matching If-None-Match is 304"
    , `Quick
    , test_json_conditional_matching_tag_is_not_modified )
  ; ( "json_lazy matching If-None-Match skips body closure"
    , `Quick
    , test_json_lazy_matching_tag_skips_body_evaluation )
  ; ( "json_lazy unmatched If-None-Match evaluates body closure"
    , `Quick
    , test_json_lazy_unmatched_tag_evaluates_body )
  ; ( "json_lazy preserves extra headers and matches wildcard/list"
    , `Quick
    , test_json_lazy_preserves_extra_headers_and_matches_wildcard )
  ; ( "stale If-None-Match sends the body"
    , `Quick
    , test_json_conditional_stale_tag_sends_the_body )
  ; ( "absent If-None-Match sends the body"
    , `Quick
    , test_json_conditional_absent_header_sends_the_body )
  ; ( "error statuses carry no validator"
    , `Quick
    , test_json_conditional_error_status_carries_no_tag )
  ; ( "unsafe methods carry no validator"
    , `Quick
    , test_json_conditional_unsafe_method_carries_no_tag )
  ; ( "the tag is weak and body-derived"
    , `Quick
    , test_json_conditional_tag_is_weak_and_body_derived )
  ; ( "a JSON response puts the validator on the wire"
    , `Quick
    , test_json_response_puts_the_validator_on_the_wire )
  ; ( "a matching tag sends no body"
    , `Quick
    , test_json_response_matching_tag_sends_no_body )
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
    [ "router", router_tests
    ; "config", config_tests
    ; "request", request_tests
    ; "response", response_tests
    ; "late_response", late_response_tests
    ]
;;
