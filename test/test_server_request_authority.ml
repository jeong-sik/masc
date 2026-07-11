open Alcotest

module Authority = Server_request_authority

let http1_request ?(headers = []) path =
  Httpun.Request.create
    ~headers:(Httpun.Headers.of_list headers)
    `GET
    path
;;

let h2_request ?(scheme = "https") ?(meth = `GET) ?(headers = []) target =
  H2.Request.create
    ~headers:(H2.Headers.of_list headers)
    ~scheme
    meth
    target
;;

let admitted_http1 headers =
  match Authority.classify_http1_request (http1_request ~headers "/") with
  | Authority.Single authority -> authority
  | Authority.Missing | Authority.Multiple | Authority.Malformed ->
    fail "expected one valid HTTP/1.1 authority"
;;

let check_classification expected actual =
  match expected, actual with
  | `Missing, Authority.Missing
  | `Multiple, Authority.Multiple
  | `Malformed, Authority.Malformed
  | `Single, Authority.Single _ ->
    ()
  | _ -> fail "unexpected request-authority classification"
;;

let test_http1_closed_classification () =
  check_classification
    `Missing
    (Authority.classify_http1_request (http1_request "/"));
  check_classification
    `Multiple
    (Authority.classify_http1_request
       (http1_request
          ~headers:[ "Host", "localhost"; "hOsT", "localhost" ]
          "/"));
  List.iter
    (fun raw ->
      check_classification
        `Malformed
        (Authority.classify_http1_request
           (http1_request ~headers:[ "host", raw ] "/")))
    [ ""
    ; "http://localhost"
    ; "user@localhost"
    ; "localhost/path"
    ; "localhost:"
    ; "localhost:65536"
    ; "localhost:8935<suffix>"
    ; "localhost:8935:80"
    ; "localhost#fragment"
    ; "[::1"
    ; "[::1]garbage"
    ; "[::1]:8935garbage"
    ]
;;

let test_http1_normalizes_authority () =
  let dns = admitted_http1 [ "host", " ExAmPlE.COM:443 " ] in
  check string "DNS case" "example.com" (Authority.host dns);
  check (option int) "explicit port" (Some 443) (Authority.port dns);
  let ipv6 = admitted_http1 [ "host", "[0:0:0:0:0:0:0:1]:8935" ] in
  check string "IPv6 canonical form" "::1" (Authority.host ipv6);
  check string "IPv6 rendered brackets" "[::1]:8935" (Authority.rendered ipv6)
;;

let check_h2_malformed request =
  match Authority.classify_h2_request request with
  | Authority.H2_authority Authority.Malformed -> ()
  | _ -> fail "expected malformed HTTP/2 authority"
;;

let test_h2_repeated_or_userinfo_authority_is_malformed () =
  check_h2_malformed
    (h2_request
       ~headers:
         [ ":authority", "example.com"; ":authority", "example.com" ]
       "/");
  check_h2_malformed
    (h2_request ~headers:[ ":authority", "user@example.com" ] "/")
;;

let test_h2_authority_whitespace_is_malformed () =
  check_h2_malformed
    (h2_request ~headers:[ ":authority", " example.com" ] "/");
  check_h2_malformed
    (h2_request ~headers:[ ":authority", "example.com " ] "/");
  check_h2_malformed
    (h2_request
       ~headers:
         [ ":authority", "example.com"; "host", "example.com " ]
       "/")
;;

let test_h2_host_is_cross_check_only () =
  let accepted headers =
    match Authority.classify_h2_request (h2_request ~headers "/") with
    | Authority.H2_authority (Authority.Single authority) -> authority
    | _ -> fail "expected H2 authority + equivalent Host to be admitted"
  in
  let dns =
    accepted [ ":authority", "Example.COM"; "host", "example.com:443" ]
  in
  check string "case-normalized authority" "example.com" (Authority.host dns);
  let ipv6 =
    accepted
      [ ":authority", "[0:0:0:0:0:0:0:1]"; "host", "[::1]:443" ]
  in
  check string "IPv6-normalized authority" "::1" (Authority.host ipv6);
  check_h2_malformed
    (h2_request
       ~headers:[ ":authority", "example.com"; "host", "other.example" ]
       "/");
  check_h2_malformed
    (h2_request
       ~headers:
         [ ":authority", "example.com"
         ; "host", "example.com"
         ; "host", "example.com"
         ]
       "/");
  (match
     Authority.classify_h2_request
       (h2_request ~headers:[ "host", "example.com" ] "/")
   with
   | Authority.H2_authority Authority.Missing -> ()
   | _ -> fail "Host without :authority must not become the H2 authority")
;;

let test_h2_default_port_normalization_is_scheme_specific () =
  let accepted ~scheme authority host =
    match
      Authority.classify_h2_request
        (h2_request
           ~scheme
           ~headers:[ ":authority", authority; "host", host ]
           "/")
    with
    | Authority.H2_authority (Authority.Single _) -> ()
    | _ -> failf "%s authority default-port normalization failed" scheme
  in
  accepted ~scheme:"http" "example.com" "EXAMPLE.COM:80";
  accepted ~scheme:"https" "example.com" "example.com:443";
  check_h2_malformed
    (h2_request
       ~scheme:"https"
       ~headers:[ ":authority", "example.com"; "host", "example.com:80" ]
       "/")
;;

let test_h2_authority_free_asterisk_is_explicitly_unsupported () =
  match
    Authority.classify_h2_request
      (h2_request ~meth:`OPTIONS ~headers:[] "*")
  with
  | Authority.Unsupported_asterisk_form_options -> ()
  | _ -> fail "authority-free OPTIONS * must have a distinct rejection"
;;

let test_h2_asterisk_does_not_mask_repeated_host () =
  check_h2_malformed
    (h2_request
       ~meth:`OPTIONS
       ~headers:[ "host", "example.com"; "host", "example.com" ]
       "*");
  check_h2_malformed
    (h2_request ~meth:`OPTIONS ~headers:[ "host", "user@example.com" ] "*")
;;

let authority_projection_routes =
  [ "/"
  ; "/dashboard"
  ; "/dashboard/keepers"
  ; "/api/v1/openapi.json"
  ; "/.well-known/agent.json"
  ; "/.well-known/agent-card.json"
  ; "/ws"
  ; "/health"
  ; "/api/v1/dashboard/dev-token"
  ]
;;

let test_projection_routes_share_case_insensitive_duplicate_gate () =
  List.iter
    (fun path ->
      let request =
        http1_request
          ~headers:[ "Host", "localhost:8935"; "hOsT", "localhost:8935" ]
          path
      in
      match Authority.classify_http1_request request with
      | Authority.Multiple -> ()
      | _ -> failf "%s bypassed the shared duplicate Host gate" path)
    authority_projection_routes
;;

let test_auth_and_cors_consume_admitted_authority () =
  let request =
    http1_request
      ~headers:
        [ "host", "localhost:8935"; "origin", "http://localhost:8935" ]
      "/api/v1/dashboard/shell"
  in
  let request_authority =
    match Authority.classify_http1_request request with
    | Authority.Single authority -> authority
    | Authority.Missing | Authority.Multiple | Authority.Malformed ->
      fail "expected admitted authority"
  in
  (match
     Server_auth.ensure_same_origin_browser_request ~request_authority request
   with
   | Ok () -> ()
   | Error error -> fail (Masc_domain.masc_error_to_string error));
  check
    (option string)
    "public CORS reflects same origin"
    (Some "http://localhost:8935")
    (Server_auth.public_read_cors_origin_opt ~request_authority request);
  let conflicting_raw_host =
    http1_request
      ~headers:
        [ "host", "attacker.example"
        ; "origin", "http://attacker.example"
        ]
      "/api/v1/dashboard/shell"
  in
  check
    (option string)
    "CORS ignores a downstream raw Host conflict"
    None
    (Server_auth.public_read_cors_origin_opt
       ~request_authority
       conflicting_raw_host);
  (match
     Server_auth.ensure_same_origin_browser_request
       ~request_authority
       conflicting_raw_host
   with
   | Error _ -> ()
   | Ok () -> fail "auth must not re-admit a conflicting downstream raw Host");
  List.iter
    (fun origin ->
      let request =
        http1_request
          ~headers:[ "host", "localhost:8935"; "origin", origin ]
          "/api/v1/dashboard/shell"
      in
      (match
         Server_auth.ensure_same_origin_browser_request
           ~request_authority
           request
       with
       | Error _ -> ()
       | Ok () -> failf "auth admitted non-HTTP(S) origin %S" origin);
      check
        (option string)
        (Printf.sprintf "CORS rejects invalid browser origin %S" origin)
        None
        (Server_auth.public_read_cors_origin_opt
           ~request_authority
           request))
    [ "evil://localhost:8935"; "http://user@localhost:8935" ]
;;

let test_mcp_origin_validation_uses_admitted_authority () =
  let request_authority = admitted_http1 [ "host", "localhost:8935" ] in
  let valid origin =
    Server_routes_http_common.validate_origin
      ~request_authority
      (http1_request ~headers:[ "origin", origin ] "/mcp")
  in
  check bool "same authority" true (valid "http://localhost:8935");
  check bool "explicit Vite loopback origin" true (valid "http://localhost:5173");
  check bool "prefix-confusable host" false (valid "http://localhost.attacker");
  check bool "non-HTTP scheme" false (valid "evil://localhost:8935");
  check bool "userinfo authority" false (valid "http://user@localhost:8935");
  check
    bool
    "native client without Origin"
    true
    (Server_routes_http_common.validate_origin
       ~request_authority
       (http1_request "/mcp"));
  check
    bool
    "POST root is MCP transport"
    true
    (Server_routes_http_common.is_mcp_transport_request
       (Httpun.Request.create `POST "/"));
  check
    bool
    "GET root is dashboard"
    false
    (Server_routes_http_common.is_mcp_transport_request
       (http1_request "/"))
;;

let test_fiber_binding_has_no_fallback () =
  Eio_main.run (fun _env ->
    let authority = admitted_http1 [ "host", "localhost:8935" ] in
    check bool "unbound before request" true (Option.is_none (Authority.current ()));
    check_raises
      "unbound lookup is explicit"
      Authority.Unbound_request_authority
      (fun () -> ignore (Authority.current_exn ()));
    Authority.with_current authority (fun () ->
      check
        string
        "bound request authority"
        "localhost:8935"
        (Authority.rendered (Authority.current_exn ())));
    check bool "unbound after request" true (Option.is_none (Authority.current ())))
;;

let () =
  run
    "server-request-authority"
    [ ( "HTTP/1.1"
      , [ test_case "closed classification" `Quick test_http1_closed_classification
        ; test_case "normalization" `Quick test_http1_normalizes_authority
        ; test_case
            "all projection routes reject duplicate Host"
            `Quick
            test_projection_routes_share_case_insensitive_duplicate_gate
        ; test_case
            "auth and CORS consume admitted authority"
            `Quick
            test_auth_and_cors_consume_admitted_authority
        ; test_case
            "MCP origin validation uses admitted authority"
            `Quick
            test_mcp_origin_validation_uses_admitted_authority
        ] )
    ; ( "HTTP/2"
      , [ test_case
            "repeated and userinfo authority malformed"
            `Quick
            test_h2_repeated_or_userinfo_authority_is_malformed
        ; test_case "Host is cross-check only" `Quick test_h2_host_is_cross_check_only
        ; test_case
            "authority whitespace malformed"
            `Quick
            test_h2_authority_whitespace_is_malformed
        ; test_case
            "scheme default-port normalization"
            `Quick
            test_h2_default_port_normalization_is_scheme_specific
        ; test_case
            "authority-free asterisk is explicit"
            `Quick
            test_h2_authority_free_asterisk_is_explicitly_unsupported
        ; test_case
            "asterisk does not mask repeated Host"
            `Quick
            test_h2_asterisk_does_not_mask_repeated_host
        ] )
    ; ( "request context"
      , [ test_case "fiber binding has no fallback" `Quick test_fiber_binding_has_no_fallback ] )
    ]
;;
