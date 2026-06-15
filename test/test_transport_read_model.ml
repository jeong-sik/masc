open Alcotest

module TRM = Masc.Transport_read_model

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

let test_websocket_discovery_uses_same_origin_upgrade_url () =
  let json = TRM.websocket_discovery_json (make_context ()) in
  check string "mode" "same_origin_upgrade"
    Yojson.Safe.Util.(json |> member "mode" |> to_string);
  check string "upgrade path" "/ws"
    Yojson.Safe.Util.(json |> member "upgrade_path" |> to_string);
  check string "ws_url uses http listener" "ws://127.0.0.1:8935/ws"
    Yojson.Safe.Util.(json |> member "ws_url" |> to_string);
  check string "standalone retained for diagnostics" "ws://127.0.0.1:8937/"
    Yojson.Safe.Util.(json |> member "standalone_ws_url" |> to_string)

let test_websocket_discovery_uses_wss_for_https_base_url () =
  let ctx =
    TRM.make_http_context
      ~base_url:"https://example.com/root/"
      ~host:"example.com"
      ()
  in
  let json = TRM.websocket_discovery_json ctx in
  check string "wss preserves base path" "wss://example.com/root/ws"
    Yojson.Safe.Util.(json |> member "ws_url" |> to_string)

let test_advertised_base_url_uses_forwarded_proto_without_internal_port () =
  let headers =
    Httpun.Headers.of_list
      [ "host", "masc.example.com"; "x-forwarded-proto", "https" ]
  in
  let request = Httpun.Request.create ~headers `GET "/ws" in
  check string "forwarded https base" "https://masc.example.com"
    (Server_routes_http_runtime.advertised_base_url request)

let test_context_from_env_uses_default_loopback_base_url () =
  with_env "MASC_HTTP_BASE_URL" None (fun () ->
      with_env "MASC_HOST" (Some "0.0.0.0") (fun () ->
          with_env "MASC_HTTP_PORT" (Some "8935") (fun () ->
              let ctx = TRM.context_from_env () in
              check string "normalized host" "127.0.0.1" ctx.host;
              check string "default base_url" "http://127.0.0.1:8935"
                ctx.base_url)))

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
             test_websocket_discovery_uses_same_origin_upgrade_url;
           test_case "websocket HTTPS URL" `Quick
             test_websocket_discovery_uses_wss_for_https_base_url;
           test_case "forwarded base URL" `Quick
             test_advertised_base_url_uses_forwarded_proto_without_internal_port;
         ] );
      ( "env",
        [
          test_case "default loopback base url" `Quick
            test_context_from_env_uses_default_loopback_base_url;
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
