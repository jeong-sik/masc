open Alcotest

module Authority = Server_request_authority

let resolve_auth_config raw =
  match Server_auth_config.resolve raw with
  | Ok config -> config
  | Error error -> fail (Server_auth_config.resolve_error_to_string error)
;;

let default_auth_config =
  resolve_auth_config
    Server_auth_config.
      { allow_anonymous_mutations = None; loopback_dev_mutation_origins = None }
;;

let () =
  match Server_auth.configure default_auth_config with
  | Ok () -> ()
  | Error error -> fail (Server_auth.configure_error_to_string error)
;;

let trust_policy ?(bind_host = "127.0.0.1") ?(bind_port = 8935) ?https_port
    ?explicit_base_url () =
  match
    Authority.make_trust_policy ~bind_host ~bind_port ~https_port ~explicit_base_url
  with
  | Ok policy -> policy
  | Error error -> fail (Authority.trust_policy_error_to_string error)
;;

let loopback_policy = trust_policy ()
let example_https_policy = trust_policy ~explicit_base_url:"https://example.com" ()

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

let admitted_http1 ?(policy = loopback_policy) headers =
  match
    Authority.classify_http1_request
      ~trust_policy:policy
      (http1_request ~headers "/")
  with
  | Authority.Single authority -> authority
  | Authority.Missing
  | Authority.Multiple
  | Authority.Malformed
  | Authority.Untrusted ->
    fail "expected one valid HTTP/1.1 authority"
;;

let check_classification expected actual =
  match expected, actual with
  | `Missing, Authority.Missing
  | `Multiple, Authority.Multiple
  | `Malformed, Authority.Malformed
  | `Untrusted, Authority.Untrusted
  | `Single, Authority.Single _ ->
    ()
  | _ -> fail "unexpected request-authority classification"
;;

let test_auth_config_rejects_malformed_values () =
  (match
     Server_auth_config.resolve
       { allow_anonymous_mutations = Some "sometimes"
       ; loopback_dev_mutation_origins = None
       }
   with
   | Error
       (Server_auth_config.Malformed_boolean
          { name = "MASC_ALLOW_ANONYMOUS_MUTATIONS"; raw = "sometimes" }) ->
     ()
   | Error _ | Ok _ -> fail "malformed anonymous-mutation flag was not rejected");
  match
    Server_auth_config.resolve
      { allow_anonymous_mutations = None
      ; loopback_dev_mutation_origins = Some "http://localhost:4173/path"
      }
  with
  | Error
      (Server_auth_config.Malformed_origin
         { name = "MASC_HTTP_DEV_MUTATION_ORIGINS"
         ; raw = "http://localhost:4173/path"
         }) ->
    ()
  | Error _ | Ok _ -> fail "malformed development Origin was not rejected"
;;

let test_auth_config_resolves_typed_policy () =
  let config =
    resolve_auth_config
      { allow_anonymous_mutations = Some "on"
      ; loopback_dev_mutation_origins = Some ""
      }
  in
  check
    bool
    "anonymous mutations"
    true
    (Server_auth_config.allow_anonymous_mutations config);
  check
    int
    "explicit empty development allowlist"
    0
    (List.length (Server_auth_config.loopback_dev_mutation_origins config))
;;

let test_auth_config_blank_anonymous_mutations_defaults_false () =
  List.iter
    (fun raw ->
       let config =
         resolve_auth_config
           { allow_anonymous_mutations = Some raw
           ; loopback_dev_mutation_origins = None
           }
       in
       check
         bool
         (Printf.sprintf "blank %S is false" raw)
         false
         (Server_auth_config.allow_anonymous_mutations config))
    [ ""; " \t " ]
;;

let test_auth_config_identical_reinstall_is_idempotent () =
  match Server_auth.configure default_auth_config with
  | Ok () -> ()
  | Error error ->
    failf
      "identical policy reinstall failed: %s"
      (Server_auth.configure_error_to_string error)
;;

let test_http1_closed_classification () =
  check_classification
    `Missing
    (Authority.classify_http1_request
       ~trust_policy:loopback_policy
       (http1_request "/"));
  check_classification
    `Multiple
    (Authority.classify_http1_request
       ~trust_policy:loopback_policy
       (http1_request
          ~headers:[ "Host", "localhost"; "hOsT", "localhost" ]
          "/"));
  List.iter
    (fun raw ->
      check_classification
        `Malformed
        (Authority.classify_http1_request
           ~trust_policy:loopback_policy
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
  let dns =
    admitted_http1
      ~policy:example_https_policy
      [ "host", " ExAmPlE.COM:443 " ]
  in
  check string "DNS case" "example.com" (Authority.host dns);
  check (option int) "explicit port" (Some 443) (Authority.port dns);
  let ipv6 = admitted_http1 [ "host", "[0:0:0:0:0:0:0:1]:8935" ] in
  check string "IPv6 canonical form" "::1" (Authority.host ipv6);
  check string "IPv6 rendered brackets" "[::1]:8935" (Authority.rendered ipv6)
;;

let check_h2_malformed request =
  match
    Authority.classify_h2_request
      ~trust_policy:example_https_policy
      request
  with
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

let test_h2_unknown_scheme_is_malformed () =
  check_h2_malformed
    (h2_request
       ~scheme:"ftp"
       ~headers:[ ":authority", "example.com" ]
       "/")
;;

let test_h2_unconfigured_authority_is_untrusted () =
  match
    Authority.classify_h2_request
      ~trust_policy:example_https_policy
      (h2_request
         ~headers:[ ":authority", "attacker.example" ]
         "/")
  with
  | Authority.H2_authority Authority.Untrusted -> ()
  | _ -> fail "unconfigured H2 authority was not rejected"
;;

let test_h2_host_is_cross_check_only () =
  let accepted ?(policy = example_https_policy) ?(scheme = "https") headers =
    match
      Authority.classify_h2_request
        ~trust_policy:policy
        (h2_request ~scheme ~headers "/")
    with
    | Authority.H2_authority (Authority.Single authority) -> authority
    | _ -> fail "expected H2 authority + equivalent Host to be admitted"
  in
  let dns =
    accepted [ ":authority", "Example.COM"; "host", "example.com:443" ]
  in
  check string "case-normalized authority" "example.com" (Authority.host dns);
  check bool "H2 scheme preserved" true (Authority.scheme dns = Authority.Https);
  check bool
    "H2 explicit trust"
    true
    (Authority.trust_class dns = Authority.Explicit_trusted_host);
  let ipv6 =
    accepted
      ~policy:loopback_policy
      ~scheme:"http"
      [ ":authority", "[0:0:0:0:0:0:0:1]:8935"; "host", "[::1]:8935" ]
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
       ~trust_policy:example_https_policy
       (h2_request ~headers:[ "host", "example.com" ] "/")
   with
   | Authority.H2_authority Authority.Missing -> ()
   | _ -> fail "Host without :authority must not become the H2 authority")
;;

let test_h2_default_port_normalization_is_scheme_specific () =
  let accepted ~scheme authority host =
    let policy =
      match scheme with
      | "http" -> trust_policy ~bind_host:"example.com" ~bind_port:80 ()
      | "https" -> example_https_policy
      | _ -> fail "test supplied an unsupported scheme"
    in
    match
      Authority.classify_h2_request
        ~trust_policy:policy
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
      ~trust_policy:example_https_policy
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
      match
        Authority.classify_http1_request
          ~trust_policy:loopback_policy
          request
      with
      | Authority.Multiple -> ()
      | _ -> failf "%s bypassed the shared duplicate Host gate" path)
    authority_projection_routes
;;

let test_dns_rebinding_host_is_untrusted_before_origin () =
  let request =
    http1_request
      ~headers:
        [ "host", "attacker.example:8935"
        ; "origin", "http://attacker.example:8935"
        ]
      "/api/v1/dashboard/shell"
  in
  check_classification
    `Untrusted
    (Authority.classify_http1_request
       ~trust_policy:loopback_policy
       request)
;;

let check_scheme label expected authority =
  check bool label true (Authority.scheme authority = expected)
;;

let check_trust label expected authority =
  check bool label true (Authority.trust_class authority = expected)
;;

(* {1 The TLS listener's own identity} *)

let tls_policy = trust_policy ~https_port:8938 ()

let admitted_h2 ?(policy = tls_policy) ?scheme authority =
  match
    Authority.classify_h2_request
      ~trust_policy:policy
      (h2_request ?scheme ~headers:[ ":authority", authority ] "/health")
  with
  | Authority.H2_authority (Authority.Single authority) -> authority
  | Authority.H2_authority
      (Authority.Missing | Authority.Multiple | Authority.Malformed | Authority.Untrusted)
  | Authority.Unsupported_asterisk_form_options ->
    failf "expected %s to be admitted" authority
;;

let untrusted_h2 ?(policy = tls_policy) ?scheme authority =
  match
    Authority.classify_h2_request
      ~trust_policy:policy
      (h2_request ?scheme ~headers:[ ":authority", authority ] "/health")
  with
  | Authority.H2_authority Authority.Untrusted -> ()
  | Authority.H2_authority
      (Authority.Single _ | Authority.Missing | Authority.Multiple | Authority.Malformed)
  | Authority.Unsupported_asterisk_form_options ->
    failf "expected %s to be untrusted" authority
;;

let untrusted_http1 ?(policy = tls_policy) host =
  check_classification
    `Untrusted
    (Authority.classify_http1_request
       ~trust_policy:policy
       (http1_request ~headers:[ "host", host ] "/health"))
;;

let test_tls_listener_identity_is_configured_bind () =
  let h2 = admitted_h2 "127.0.0.1:8938" in
  check string "host" "127.0.0.1" (Authority.host h2);
  check (option int) "port" (Some 8938) (Authority.port h2);
  check_scheme "h2 scheme is the listener's" Authority.Https h2;
  check_trust "h2 trust is the listener's own" Authority.Configured_bind h2;
  check bool "the listener is loopback" true (Authority.listener_is_loopback h2);
  let localhost = admitted_h2 "localhost:8938" in
  check string "loopback names are equivalent" "localhost" (Authority.host localhost);
  check_trust "localhost trust" Authority.Configured_bind localhost;
  (* HTTP/1.1 over TLS carries the same authority in Host. *)
  let h1 = admitted_http1 ~policy:tls_policy [ "host", "127.0.0.1:8938" ] in
  check_scheme "h1 scheme is the listener's" Authority.Https h1;
  check_trust "h1 trust is the listener's own" Authority.Configured_bind h1;
  check (option int) "h1 port" (Some 8938) (Authority.port h1);
  (* The cleartext bind is admitted exactly as before. *)
  let cleartext = admitted_h2 ~scheme:"http" "127.0.0.1:8935" in
  check_scheme "cleartext scheme" Authority.Http cleartext;
  check_trust "cleartext trust" Authority.Configured_bind cleartext
;;

let test_tls_listener_identity_needs_the_configured_port () =
  (* No TLS listener: its would-be authority is a stranger. *)
  untrusted_h2 ~policy:loopback_policy "127.0.0.1:8938";
  untrusted_http1 ~policy:loopback_policy "127.0.0.1:8938";
  (* Another port, the cleartext port, the scheme default, or the cleartext
     scheme are not the TLS listener. *)
  untrusted_h2 "127.0.0.1:8939";
  untrusted_h2 "127.0.0.1:8935";
  untrusted_h2 "127.0.0.1";
  untrusted_h2 ~scheme:"http" "127.0.0.1:8938";
  untrusted_http1 "127.0.0.1:8939";
  untrusted_http1 "127.0.0.1";
  (* A non-loopback name on the listener port is not the listener. *)
  untrusted_h2 "attacker.example:8938";
  untrusted_http1 "attacker.example:8938"
;;

let test_tls_listener_identity_keeps_explicit_precedence () =
  let policy =
    trust_policy
      ~bind_host:"0.0.0.0"
      ~https_port:8938
      ~explicit_base_url:"https://masc.example.test:9443/root"
      ()
  in
  let public = admitted_http1 ~policy [ "host", "masc.example.test:9443" ] in
  check_trust "public host stays explicit" Authority.Explicit_trusted_host public;
  check_scheme "public scheme" Authority.Https public;
  let own = admitted_h2 ~policy "127.0.0.1:8938" in
  check_trust "wildcard bind projects the TLS identity to loopback"
    Authority.Configured_bind own;
  check bool "wildcard listener is not loopback" false (Authority.listener_is_loopback own);
  let projected = Authority.projection_context policy in
  check string "background projection keeps the public host"
    "masc.example.test" (Authority.host projected)
;;

(* The cleartext bind is matched before the TLS identity on HTTP/1.1, so a
   policy whose two ports coincide (a misconfiguration the bootstrap never
   produces: the TLS bind fails and no identity is added) still classifies
   the shared port as the cleartext listener. *)
let test_tls_listener_identity_yields_to_the_cleartext_bind () =
  let policy = trust_policy ~bind_port:8938 ~https_port:8938 () in
  let h1 = admitted_http1 ~policy [ "host", "127.0.0.1:8938" ] in
  check_scheme "shared port is the cleartext bind on HTTP/1.1" Authority.Http h1;
  check_trust "shared port trust" Authority.Configured_bind h1;
  check_scheme "HTTP/2 with :scheme https is still the TLS identity"
    Authority.Https (admitted_h2 ~policy "127.0.0.1:8938")
;;

let test_tls_listener_port_is_validated () =
  match
    Authority.make_trust_policy
      ~bind_host:"127.0.0.1"
      ~bind_port:8935
      ~https_port:(Some 70000)
      ~explicit_base_url:None
  with
  | Ok _ -> fail "a TLS port above 65535 was accepted"
  | Error Authority.Malformed_tls_authority -> ()
  | Error (Authority.Malformed_bind_authority | Authority.Malformed_explicit_base_url) ->
    fail "the TLS port was blamed on another identity"
;;

(* A server started with --host ::1 writes its own base URL and reads it back
   as the explicit trusted identity. Without brackets the URL was
   http://::1:18977, the policy refused it, and the boot ended (#46375,
   #51833). *)
let test_ipv6_listener_base_url_is_its_own_trusted_identity () =
  let port = 18977 in
  let base_url =
    Server_bootstrap_http.advertised_base_url
      ~address:(Ipaddr.V6 Ipaddr.V6.localhost)
      ~port
  in
  check string "base URL of a listener on ::1" "http://[::1]:18977" base_url;
  let policy =
    trust_policy ~bind_host:"::1" ~bind_port:port ~explicit_base_url:base_url ()
  in
  let admitted = admitted_http1 ~policy [ "Host", "[::1]:18977" ] in
  check string "admitted authority keeps the brackets" "[::1]:18977"
    (Authority.rendered admitted);
  check string "a wildcard IPv6 listener is dialled on the loopback peer"
    "http://127.0.0.1:18977"
    (Server_bootstrap_http.advertised_base_url
       ~address:(Ipaddr.V6 Ipaddr.V6.unspecified)
       ~port);
  let global = "fd00::1" in
  let global_url =
    Server_bootstrap_http.advertised_base_url
      ~address:(Ipaddr.of_string_exn global)
      ~port
  in
  check string "base URL of a listener on a routed IPv6 address"
    "http://[fd00::1]:18977" global_url;
  let global_policy =
    trust_policy ~bind_host:global ~bind_port:port ~explicit_base_url:global_url ()
  in
  check string "its Host is admitted with brackets" "[fd00::1]:18977"
    (Authority.rendered
       (admitted_http1 ~policy:global_policy [ "Host", "[fd00::1]:18977" ]))
;;

let test_request_context_preserves_scheme_and_trust () =
  let local = admitted_http1 [ "host", "localhost:8935" ] in
  check_scheme "local scheme" Authority.Http local;
  check_trust "local trust" Authority.Configured_bind local;
  let external_policy =
    trust_policy
      ~bind_host:"0.0.0.0"
      ~explicit_base_url:"https://masc.example.test:9443/root"
      ()
  in
  let external_authority =
    admitted_http1
      ~policy:external_policy
      [ "host", "masc.example.test:9443" ]
  in
  check_scheme "external scheme" Authority.Https external_authority;
  check_trust
    "external trust"
    Authority.Explicit_trusted_host
    external_authority;
  let projected = Authority.projection_context external_policy in
  check string "background projection uses public host"
    "masc.example.test" (Authority.host projected);
  check_scheme "background projection uses public scheme" Authority.Https projected;
  check_trust
    "background projection keeps public trust"
    Authority.Explicit_trusted_host
    projected
;;

let test_trust_policy_has_no_permissive_default () =
  (match
     Authority.make_trust_policy
       ~bind_host:"0.0.0.0"
       ~bind_port:8935 ~https_port:None
       ~explicit_base_url:(Some "ftp://attacker.example")
   with
   | Error Authority.Malformed_explicit_base_url -> ()
   | Error (Authority.Malformed_bind_authority | Authority.Malformed_tls_authority)
   | Ok _ ->
     fail "malformed explicit trusted host did not fail closed");
  let wildcard_only = trust_policy ~bind_host:"0.0.0.0" () in
  check_classification
    `Untrusted
    (Authority.classify_http1_request
       ~trust_policy:wildcard_only
       (http1_request ~headers:[ "host", "attacker.example:8935" ] "/"))
;;

let check_origin_admission label expected request_authority headers =
  match
    Server_auth.classify_request_origin
      ~request_authority
      (http1_request ~headers "/")
  with
  | Server_auth.Single_origin { admission; _ } ->
    check bool label true (admission = expected)
  | Server_auth.Missing_origin
  | Server_auth.Multiple_origins
  | Server_auth.Malformed_origin ->
    failf "%s did not produce one parsed Origin" label
;;

let test_auth_config_is_resolved_once_before_origin_admission () =
  let configured =
    resolve_auth_config
      { allow_anonymous_mutations = None
      ; loopback_dev_mutation_origins = Some "http://localhost:4173"
      }
  in
  (match Server_auth.configure configured with
   | Error Server_auth.Already_configured -> ()
   | Ok () -> fail "authorization policy accepted a second production install");
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_auth_config (Some default_auth_config))
    (fun () ->
      Server_auth.For_testing.restore_auth_config (Some configured);
      let request_authority = admitted_http1 [ "host", "localhost:8935" ] in
      check_origin_admission
        "configured development Origin"
        Server_auth.Allowed_dev_origin
        request_authority
        [ "origin", "http://localhost:4173" ];
      check_origin_admission
        "unconfigured default Origin"
        Server_auth.Rejected
        request_authority
        [ "origin", "http://localhost:5173" ])
;;

let test_origin_exact_grammar_and_cardinality () =
  let request_authority = admitted_http1 [ "host", "localhost:8935" ] in
  check_origin_admission
    "same origin"
    Server_auth.Same_origin
    request_authority
    [ "origin", "http://localhost:8935" ];
  check_origin_admission
    "wrong scheme"
    Server_auth.Rejected
    request_authority
    [ "origin", "https://localhost:8935" ];
  check_origin_admission
    "loopback alias is not same origin"
    Server_auth.Rejected
    request_authority
    [ "origin", "http://127.0.0.1:8935" ];
  check_origin_admission
    "explicit Vite origin"
    Server_auth.Allowed_dev_origin
    request_authority
    [ "origin", "http://localhost:5173" ];
  List.iter
    (fun origin ->
      match
        Server_auth.classify_request_origin
          ~request_authority
          (http1_request ~headers:[ "origin", origin ] "/")
      with
      | Server_auth.Malformed_origin -> ()
      | _ -> failf "accepted non-serialized Origin %S" origin)
    [ "http://localhost:8935/"
    ; "http://localhost:8935/path"
    ; "http://localhost:8935?query=1"
    ; "http://localhost:8935#fragment"
    ; "http://localhost:8935 http://attacker.example"
    ; "http://localhost:8935trailing"
    ];
  (match
     Server_auth.classify_request_origin
       ~request_authority
       (http1_request
          ~headers:
            [ "Origin", "http://localhost:8935"
            ; "oRiGiN", "http://localhost:8935"
            ]
          "/")
   with
   | Server_auth.Multiple_origins -> ()
   | _ -> fail "duplicate Origin fields were not rejected")
;;

let test_custom_trusted_https_origin () =
  let policy =
    trust_policy
      ~bind_host:"0.0.0.0"
      ~explicit_base_url:"https://masc.example.test:9443/root"
      ()
  in
  let request_authority =
    admitted_http1
      ~policy
      [ "host", "masc.example.test:9443" ]
  in
  check_origin_admission
    "custom trusted HTTPS"
    Server_auth.Same_origin
    request_authority
    [ "origin", "https://masc.example.test:9443" ];
  check_origin_admission
    "custom trusted wrong HTTP scheme"
    Server_auth.Rejected
    request_authority
    [ "origin", "http://masc.example.test:9443" ]
;;

let test_referer_keeps_separate_url_grammar () =
  let request_authority = admitted_http1 [ "host", "localhost:8935" ] in
  let request =
    http1_request
      ~headers:
        [ "referer", "http://localhost:8935/dashboard/keepers?tab=active" ]
      "/api/v1/dashboard/shell"
  in
  (match
     Server_auth.ensure_same_origin_browser_request ~request_authority request
   with
   | Ok () -> ()
   | Error error -> fail (Masc_domain.masc_error_to_string error))
;;

let test_missing_origin_and_referer_names_masc_login () =
  let request_authority = admitted_http1 [ "host", "localhost:8935" ] in
  let request =
    http1_request ~headers:[ "host", "localhost:8935" ] "/api/v1/dashboard/shell"
  in
  match
    Server_auth.ensure_same_origin_browser_request ~request_authority request
  with
  | Ok () -> fail "expected Missing_token rejection when Origin and Referer are absent"
  | Error (Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized { reason = Missing_token; message })) ->
    check
      bool
      "401 message guides operator to masc login with required --client-env"
      true
      (String_util.contains_substring
         message
         "masc login --base-path <dir> --client-env MASC_TOKEN")
  | Error error ->
    fail ("unexpected error variant: " ^ Masc_domain.masc_error_to_string error)
;;

let test_wildcard_bind_keeps_internal_and_public_loopback_identities () =
  let policy =
    trust_policy
      ~bind_host:"0.0.0.0"
      ~bind_port:8080
      ~explicit_base_url:"http://localhost:9546"
      ()
  in
  let internal_authority =
    admitted_http1 ~policy [ "host", "localhost:8080" ]
  in
  check_trust
    "internal listener keeps configured trust"
    Authority.Configured_bind
    internal_authority;
  let public_authority =
    admitted_http1 ~policy [ "host", "127.0.0.1:9546" ]
  in
  check_trust
    "mapped loopback alias uses explicit trust"
    Authority.Explicit_trusted_host
    public_authority;
  check_origin_admission
    "preserved Host alias remains exact origin"
    Server_auth.Same_origin
    public_authority
    [ "origin", "http://127.0.0.1:9546" ];
  check_classification
    `Untrusted
    (Authority.classify_http1_request
       ~trust_policy:policy
       (http1_request ~headers:[ "host", "localhost:9999" ] "/"))
;;

let test_auth_and_cors_consume_admitted_authority () =
  let request =
    http1_request
      ~headers:
        [ "host", "localhost:8935"; "origin", "http://localhost:8935" ]
      "/api/v1/dashboard/shell"
  in
  let request_authority =
    match
      Authority.classify_http1_request
        ~trust_policy:loopback_policy
        request
    with
    | Authority.Single authority -> authority
    | Authority.Missing
    | Authority.Multiple
    | Authority.Malformed
    | Authority.Untrusted ->
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
    [ ( "auth config"
      , [ test_case
            "malformed values are rejected"
            `Quick
            test_auth_config_rejects_malformed_values
        ; test_case
            "policy is typed"
            `Quick
            test_auth_config_resolves_typed_policy
        ; test_case
            "blank anonymous mutations default false"
            `Quick
            test_auth_config_blank_anonymous_mutations_defaults_false
        ; test_case
            "identical policy reinstall is idempotent"
            `Quick
            test_auth_config_identical_reinstall_is_idempotent
        ; test_case
            "policy is resolved before admission"
            `Quick
            test_auth_config_is_resolved_once_before_origin_admission
        ] )
    ; ( "HTTP/1.1"
      , [ test_case "closed classification" `Quick test_http1_closed_classification
        ; test_case "normalization" `Quick test_http1_normalizes_authority
        ; test_case
            "all projection routes reject duplicate Host"
            `Quick
            test_projection_routes_share_case_insensitive_duplicate_gate
        ; test_case
            "DNS rebinding Host is untrusted"
            `Quick
            test_dns_rebinding_host_is_untrusted_before_origin
        ; test_case
            "Origin grammar and cardinality are exact"
            `Quick
            test_origin_exact_grammar_and_cardinality
        ; test_case
            "custom trusted HTTPS origin"
            `Quick
            test_custom_trusted_https_origin
        ; test_case
            "wildcard bind preserves internal and public loopback identities"
            `Quick
            test_wildcard_bind_keeps_internal_and_public_loopback_identities
        ; test_case
            "Referer keeps separate URL grammar"
            `Quick
            test_referer_keeps_separate_url_grammar
        ; test_case
            "missing Origin and Referer names masc login"
            `Quick
            test_missing_origin_and_referer_names_masc_login
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
            "unknown scheme malformed"
            `Quick
            test_h2_unknown_scheme_is_malformed
        ; test_case
            "unconfigured authority untrusted"
            `Quick
            test_h2_unconfigured_authority_is_untrusted
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
      , [ test_case
            "scheme and trust provenance"
            `Quick
            test_request_context_preserves_scheme_and_trust
        ; test_case "fiber binding has no fallback" `Quick test_fiber_binding_has_no_fallback
        ; test_case
            "trust policy has no permissive default"
            `Quick
            test_trust_policy_has_no_permissive_default
        ] )
    ; ( "TLS listener identity"
      , [ test_case
            "listener host and port are its own identity"
            `Quick
            test_tls_listener_identity_is_configured_bind
        ; test_case
            "only the configured port and scheme"
            `Quick
            test_tls_listener_identity_needs_the_configured_port
        ; test_case
            "explicit identity keeps precedence"
            `Quick
            test_tls_listener_identity_keeps_explicit_precedence
        ; test_case
            "cleartext bind is matched first on HTTP/1.1"
            `Quick
            test_tls_listener_identity_yields_to_the_cleartext_bind
        ; test_case "port is validated" `Quick test_tls_listener_port_is_validated
        ; test_case
            "an IPv6 listener trusts the base URL it writes"
            `Quick
            test_ipv6_listener_base_url_is_its_own_trusted_identity
        ] )
    ]
;;
