open Alcotest

module TRM = Masc.Transport_read_model
module TM = Masc.Transport_metrics

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

let rec strip_configured = function
  | `Assoc fields ->
      `Assoc
        (fields
         |> List.filter_map (fun (key, value) ->
                if String.equal key "configured" then None
                else Some (key, strip_configured value)))
  | `List values -> `List (List.map strip_configured values)
  | other -> other

let make_context ?(include_configured = false) () =
  TRM.make_http_context ~include_configured ~base_url:"http://127.0.0.1:8935"
    ~host:"127.0.0.1" ()

let with_ws_same_origin_ready f =
  TM.set_ws_same_origin_runtime_ready true;
  Fun.protect ~finally:(fun () -> TM.set_ws_same_origin_runtime_ready false) f

let test_websocket_discovery_http_shape_extends_tool_shape () =
  let tool_json = TRM.websocket_discovery_json (make_context ()) in
  let http_json =
    TRM.websocket_discovery_json (make_context ~include_configured:true ())
  in
  check bool "http surface adds configured"
    true
    (match Yojson.Safe.Util.member "configured" http_json with
    | `Bool _ -> true
    | _ -> false);
  check bool "tool and http surfaces match after stripping configured"
    true (tool_json = strip_configured http_json)

let test_transport_status_http_shape_extends_tool_shape () =
  let tool_json = TRM.transport_status_json (make_context ()) in
  let http_json =
    TRM.transport_status_json (make_context ~include_configured:true ())
  in
  check bool "http grpc surface adds configured"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "grpc" |> member "configured")
     with
    | `Bool _ -> true
    | _ -> false);
  check bool "http webrtc surface adds configured"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "webrtc" |> member "configured")
     with
    | `Bool _ -> true
    | _ -> false);
  check bool "http surface exposes streamable configured"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "http" |> member "configured")
     with
    | `Bool _ -> true
    | _ -> false);
  check bool "http surface exposes streamable protocol capability"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "http" |> member "protocol_capable")
     with
    | `Bool _ -> true
    | _ -> false);
  check bool "http surface exposes auth policy dimension"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "http" |> member "auth_policy_present")
     with
    | `Bool _ -> true
    | _ -> false);
  check string "http surface reports canonical observer SSE URL"
    "http://127.0.0.1:8935/mcp?sse_kind=observer"
    Yojson.Safe.Util.(http_json |> member "http" |> member "sse_url" |> to_string);
  check bool "grpc surface exposes reachability"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "grpc" |> member "reachable")
     with
    | `Bool _ -> true
    | _ -> false);
  check bool "websocket surface exposes reachability"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "websocket" |> member "reachable")
     with
    | `Bool _ -> true
    | _ -> false);
  check bool "webrtc surface exposes signaling availability"
    true
    (match
       Yojson.Safe.Util.(http_json |> member "webrtc" |> member "signaling_available")
     with
    | `Bool _ -> true
    | _ -> false);
  check bool "tool and http transport status match after stripping configured"
     true (tool_json = strip_configured http_json)

let test_transport_status_reports_streamable_http_protocol () =
  let json = TRM.transport_status_json (make_context ()) in
  let enabled_protocols =
    Yojson.Safe.Util.(json |> member "enabled_protocols" |> to_list)
    |> List.map Yojson.Safe.Util.to_string
  in
  check bool "enabled_protocols includes canonical json-rpc path" true
    (List.mem "json-rpc" enabled_protocols)

let test_websocket_discovery_uses_same_origin_url () =
  with_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    with_ws_same_origin_ready (fun () ->
      TM.set_ws_runtime_listening true;
      Fun.protect
        ~finally:(fun () -> TM.set_ws_runtime_listening false)
        (fun () ->
          let json = TRM.websocket_discovery_json (make_context ()) in
          check string "mode" "same_origin"
            Yojson.Safe.Util.(json |> member "mode" |> to_string);
          check string "upgrade path" "/ws"
            Yojson.Safe.Util.(json |> member "upgrade_path" |> to_string);
          check string "ws_url uses same-origin listener" "ws://127.0.0.1:8935/ws"
            Yojson.Safe.Util.(json |> member "ws_url" |> to_string);
          check string "standalone bind host is explicit" "127.0.0.1"
            Yojson.Safe.Util.(json |> member "standalone_bind_host" |> to_string);
          check bool "same-origin upgrade is marked enabled" true
            Yojson.Safe.Util.(json |> member "same_origin_upgrade_enabled" |> to_bool);
          check bool "same-origin reachability is explicit" true
            Yojson.Safe.Util.(json |> member "same_origin_reachable" |> to_bool);
          check string "standalone diagnostic is retained" "ws://127.0.0.1:8937/"
            Yojson.Safe.Util.(json |> member "standalone_ws_url" |> to_string);
          check string "same-origin retained for diagnostics" "ws://127.0.0.1:8935/ws"
            Yojson.Safe.Util.(json |> member "same_origin_ws_url" |> to_string))))

let test_websocket_discovery_advertises_same_origin_ws_to_remote_host () =
  with_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    with_ws_same_origin_ready (fun () ->
      TM.set_ws_runtime_listening true;
      Fun.protect
        ~finally:(fun () -> TM.set_ws_runtime_listening false)
        (fun () ->
          let ctx =
            TRM.make_http_context
              ~base_url:"http://192.0.2.10:8935"
              ~host:"192.0.2.10"
              ()
          in
          let json = TRM.websocket_discovery_json ctx in
          check bool "standalone process is listening" true
            Yojson.Safe.Util.(json |> member "standalone_listening" |> to_bool);
          check bool "remote host cannot reach loopback standalone listener" false
            Yojson.Safe.Util.(
              json |> member "request_host_can_reach_standalone" |> to_bool);
          check bool "same-origin listener is reachable from request origin" true
            Yojson.Safe.Util.(json |> member "reachable" |> to_bool);
          check bool "request host reachability is explicit" false
            Yojson.Safe.Util.(
              json |> member "request_host_can_reach_standalone" |> to_bool);
          check string "standalone diagnostic still reports bind URL"
            "ws://127.0.0.1:8937/"
            Yojson.Safe.Util.(json |> member "standalone_ws_url" |> to_string);
          check string "primary client ws_url uses same-origin"
            "ws://192.0.2.10:8935/ws"
            Yojson.Safe.Util.(json |> member "ws_url" |> to_string);
          check bool "loopback-only reason is absent when same-origin is primary"
            true
            (match Yojson.Safe.Util.member "unavailable_reason" json with
             | `Null -> true
             | _ -> false))))

let test_websocket_discovery_distinguishes_standalone_from_same_origin () =
  with_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    with_ws_same_origin_ready (fun () ->
      TM.set_ws_runtime_listening false;
      let json = TRM.websocket_discovery_json (make_context ()) in
      check bool "enabled still advertises configured websocket" true
        Yojson.Safe.Util.(json |> member "enabled" |> to_bool);
      check bool "same-origin upgrade makes primary listener available" true
        Yojson.Safe.Util.(json |> member "listening" |> to_bool);
      check bool "same-origin upgrade makes primary websocket reachable" true
        Yojson.Safe.Util.(json |> member "reachable" |> to_bool);
      check bool "standalone listener state remains explicit" false
        Yojson.Safe.Util.(json |> member "standalone_listening" |> to_bool)))

let test_websocket_discovery_waits_for_same_origin_dispatcher () =
  with_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    TM.set_ws_runtime_listening false;
    TM.set_ws_same_origin_runtime_ready false;
    let ctx =
      TRM.make_http_context
        ~base_url:"http://192.0.2.10:8935"
        ~host:"192.0.2.10"
        ()
    in
    let json = TRM.websocket_discovery_json ctx in
    check bool "websocket remains configured" true
      Yojson.Safe.Util.(json |> member "enabled" |> to_bool);
    check bool "same-origin upgrade is not advertised before dispatcher" false
      Yojson.Safe.Util.(json |> member "same_origin_upgrade_enabled" |> to_bool);
    check bool "no primary listener is advertised before dispatcher" false
      Yojson.Safe.Util.(json |> member "listening" |> to_bool);
    check bool "remote host has no reachable websocket before dispatcher" false
      Yojson.Safe.Util.(json |> member "reachable" |> to_bool);
    check bool "primary client ws_url is withheld"
      true
      (match Yojson.Safe.Util.member "ws_url" json with
       | `Null -> true
       | _ -> false))

let test_websocket_discovery_retains_same_origin_wss_diagnostic () =
  with_env "MASC_WS_ENABLED" (Some "true") (fun () ->
    with_ws_same_origin_ready (fun () ->
      let ctx =
        TRM.make_http_context
          ~base_url:"https://example.com/root/"
          ~host:"example.com"
          ()
      in
      let json = TRM.websocket_discovery_json ctx in
      check string "wss preserves base path" "wss://example.com/root/ws"
        Yojson.Safe.Util.(json |> member "same_origin_ws_url" |> to_string);
      check string "primary ws_url uses same-origin wss" "wss://example.com/root/ws"
        Yojson.Safe.Util.(json |> member "ws_url" |> to_string)))

let test_advertised_base_url_uses_typed_trusted_scheme () =
  let headers =
    Httpun.Headers.of_list
      [ "host", "masc.example.com"; "x-forwarded-proto", "http" ]
  in
  let request = Httpun.Request.create ~headers `GET "/ws" in
  let request_authority =
    let trust_policy =
      match
        Server_request_authority.make_trust_policy
          ~bind_host:"0.0.0.0"
          ~bind_port:8935
          ~explicit_base_url:(Some "https://masc.example.com")
      with
      | Ok policy -> policy
      | Error error ->
        fail (Server_request_authority.trust_policy_error_to_string error)
    in
    match
      Server_request_authority.classify_http1_request ~trust_policy request
    with
    | Server_request_authority.Single authority -> authority
    | ( Server_request_authority.Missing
      | Server_request_authority.Multiple
      | Server_request_authority.Malformed
      | Server_request_authority.Untrusted ) ->
      fail "expected valid authority"
  in
  check string "trusted HTTPS base" "https://masc.example.com"
    (Server_routes_http_runtime.advertised_base_url
       ~request_authority
       request);
  with_env "MASC_HTTP_PORT" (Some "9000") (fun () ->
      let host, port =
        Server_routes_http_runtime.advertised_host_port ~request_authority
      in
      check string "typed authority host" "masc.example.com" host;
      check int "typed HTTPS default port" 443 port)

let test_context_from_env_uses_default_loopback_base_url () =
  with_env "MASC_HTTP_BASE_URL" None (fun () ->
      with_env "MASC_HOST" (Some "0.0.0.0") (fun () ->
          with_env "MASC_HTTP_PORT" (Some "8935") (fun () ->
              let ctx = TRM.context_from_env () in
              check string "normalized host" "127.0.0.1" ctx.host;
              check string "default base_url" "http://127.0.0.1:8935"
                ctx.base_url)))

let test_explicit_base_url_opt_never_derives_from_bind_env () =
  with_env "MASC_HTTP_BASE_URL" None (fun () ->
      with_env "MASC_HOST" (Some "0.0.0.0") (fun () ->
          with_env "MASC_HTTP_PORT" (Some "9000") (fun () ->
              check
                (option string)
                "listener env is not an explicit public identity"
                None
                (Env_config_core.masc_http_base_url_opt ()))))

let test_explicit_base_url_opt_normalizes_only_explicit_value () =
  with_env
    "MASC_HTTP_BASE_URL"
    (Some "  https://example.com/root///  ")
    (fun () ->
       check
         (option string)
         "explicit public identity is normalized"
         (Some "https://example.com/root")
         (Env_config_core.masc_http_base_url_opt ()))

let test_context_from_env_trims_explicit_base_url () =
  with_env "MASC_HTTP_BASE_URL" (Some "https://example.com/root/") (fun () ->
      let ctx = TRM.context_from_env () in
      check string "host derived from base url" "example.com" ctx.host;
      check string "base_url trimmed" "https://example.com/root" ctx.base_url)

let test_context_from_env_normalizes_loopback_alias_base_url () =
  with_env "MASC_HTTP_BASE_URL" (Some "http://localhost:8935/root/") (fun () ->
      let ctx = TRM.context_from_env () in
      check string "loopback alias host canonicalized" "127.0.0.1" ctx.host;
      check string "loopback alias base_url canonicalized"
        "http://127.0.0.1:8935/root" ctx.base_url)

let test_normalize_advertised_host_canonicalizes_localhost () =
  check string "localhost normalizes to loopback" "127.0.0.1"
    (TRM.normalize_advertised_host "localhost")

let test_normalize_advertised_host_canonicalizes_ipv6_loopback () =
  check string "::1 normalizes to IPv4 loopback" "127.0.0.1"
    (TRM.normalize_advertised_host "::1")

let test_normalize_advertised_host_preserves_noncanonical_127_alias () =
  check string "127.0.1.1 stays explicit" "127.0.1.1"
    (TRM.normalize_advertised_host "127.0.1.1")

let () =
  run "Transport_read_model"
    [
      ( "json",
        [
           test_case "websocket discovery parity" `Quick
             test_websocket_discovery_http_shape_extends_tool_shape;
           test_case "transport status parity" `Quick
             test_transport_status_http_shape_extends_tool_shape;
           test_case "transport status includes json-rpc protocol" `Quick
             test_transport_status_reports_streamable_http_protocol;
           test_case "websocket same-origin URL" `Quick
             test_websocket_discovery_uses_same_origin_url;
           test_case "websocket remote host gets same-origin URL" `Quick
             test_websocket_discovery_advertises_same_origin_ws_to_remote_host;
           test_case "websocket standalone state stays explicit" `Quick
             test_websocket_discovery_distinguishes_standalone_from_same_origin;
           test_case "websocket waits for same-origin dispatcher" `Quick
             test_websocket_discovery_waits_for_same_origin_dispatcher;
           test_case "websocket HTTPS diagnostic URL" `Quick
             test_websocket_discovery_retains_same_origin_wss_diagnostic;
           test_case "typed trusted base URL" `Quick
             test_advertised_base_url_uses_typed_trusted_scheme;
         ] );
      ( "env",
        [
          test_case "default loopback base url" `Quick
            test_context_from_env_uses_default_loopback_base_url;
          test_case "explicit base URL does not derive bind env" `Quick
            test_explicit_base_url_opt_never_derives_from_bind_env;
          test_case "explicit base URL normalizes explicit value" `Quick
            test_explicit_base_url_opt_normalizes_only_explicit_value;
          test_case "trim explicit base url" `Quick
            test_context_from_env_trims_explicit_base_url;
          test_case "normalize loopback alias base url" `Quick
            test_context_from_env_normalizes_loopback_alias_base_url;
          test_case "normalize localhost" `Quick
            test_normalize_advertised_host_canonicalizes_localhost;
          test_case "normalize ipv6 loopback" `Quick
            test_normalize_advertised_host_canonicalizes_ipv6_loopback;
          test_case "preserve noncanonical 127 alias" `Quick
            test_normalize_advertised_host_preserves_noncanonical_127_alias;
        ] );
    ]
