(** Tool_misc_transport — Transport, WebSocket, and WebRTC tool handlers.

    Extracted from tool_misc.ml to reduce god file size.
    Contains HTTP/WS/gRPC/WebRTC discovery and status handlers.

    @since 2.188.0 — God file decomposition Phase 1 *)

open Tool_args

type result = bool * string

(* ================================================================ *)
(* Local helpers (duplicated from tool_misc to avoid circular deps) *)
(* ================================================================ *)

let encode_string_list values =
  `List (List.map (fun value -> `String value) values)

let pretty_json_string raw =
  try Yojson.Safe.from_string raw |> Yojson.Safe.pretty_to_string
  with Yojson.Json_error _ -> raw

let rec trim_trailing_slashes value =
  let len = String.length value in
  if len > 0 && value.[len - 1] = '/' then
    trim_trailing_slashes (String.sub value 0 (len - 1))
  else
    value

let trim_nonempty value =
  let trimmed = String.trim value in
  if trimmed = "" then None else Some trimmed

let env_flag_enabled name =
  match Sys.getenv_opt name with
  | None -> false
  | Some raw ->
      let v = String.trim raw |> String.lowercase_ascii in
      v = "1" || v = "true" || v = "yes" || v = "y" || v = "on"

(* ================================================================ *)
(* HTTP/Transport helpers                                           *)
(* ================================================================ *)

let configured_http_port () =
  Env_config_core.masc_http_port_int ()

let configured_http_host () =
  Env_config_core.masc_host ()

let ipaddr_is_unspecified = function
  | Ipaddr.V4 addr -> Ipaddr.V4.compare addr Ipaddr.V4.any = 0
  | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0

let is_unspecified_host host =
  match Ipaddr.of_string (String.trim host) with
  | Ok ip -> ipaddr_is_unspecified ip
  | Error _ -> false

let normalize_advertised_host host =
  if is_unspecified_host host then "127.0.0.1" else host

let effective_http_base_url () =
  match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
  | Some raw -> (
      match trim_nonempty raw with
      | Some value -> trim_trailing_slashes value
      | None ->
          let host = configured_http_host () |> normalize_advertised_host in
          Printf.sprintf "http://%s:%d" host (configured_http_port ()))
  | None ->
      let host = configured_http_host () |> normalize_advertised_host in
      Printf.sprintf "http://%s:%d" host (configured_http_port ())

let advertised_http_host_port () =
  let base_url = effective_http_base_url () in
  let uri = Uri.of_string base_url in
  let host =
    match Uri.host uri with
    | Some value -> normalize_advertised_host value
    | None -> configured_http_host () |> normalize_advertised_host
  in
  let port =
    match Uri.port uri with
    | Some value -> value
    | None -> (
        match Uri.scheme uri with
        | Some "https" -> 443
        | _ -> configured_http_port ())
  in
  (base_url, host, port)

(* ================================================================ *)
(* JSON builders                                                    *)
(* ================================================================ *)

let websocket_discovery_json () =
  let (_, host, _) = advertised_http_host_port () in
  let enabled = Server_ws_standalone.is_enabled () in
  let port = Server_ws_standalone.configured_port () in
  let base_fields =
    [
      ("enabled", `Bool enabled);
      ("listening", `Bool (Atomic.get Transport_metrics.ws_runtime_listening));
      ("listen_status", `String (Atomic.get Transport_metrics.ws_listen_status));
      ("mode", `String "standalone");
      ("discovery_path", `String "/ws");
      ("session_count", `Int (Server_mcp_transport_ws.session_count ()));
    ]
  in
  let fields =
    if enabled then
      base_fields
      @
      [
        ("ws_port", `Int port);
        ("ws_url", `String (Printf.sprintf "ws://%s:%d/" host port));
      ]
    else
      base_fields
  in
  `Assoc fields

let transport_status_json () =
  let (base_url, host, _) = advertised_http_host_port () in
  let grpc_enabled = Masc_grpc_server.is_enabled () in
  let grpc_port = Masc_grpc_server.configured_port () in
  let webrtc_enabled = Server_webrtc_transport.is_enabled () in
  `Assoc
    [
      ("streamable_http_default", `Bool true);
      ("allow_legacy_accept", `Bool (env_flag_enabled "MASC_ALLOW_LEGACY_ACCEPT"));
      ("legacy_endpoints_deprecated", `Bool true);
      ( "http",
        `Assoc
          [
            ("enabled", `Bool true);
            ("base_url", `String base_url);
            ("mcp_url", `String (base_url ^ "/mcp"));
            ("sse_url", `String (base_url ^ "/sse"));
          ] );
      ( "grpc",
        `Assoc
          ([
             ("enabled", `Bool grpc_enabled);
             ("listening", `Bool (Transport_metrics.grpc_listening ()));
             ("listen_status", `String (Atomic.get Transport_metrics.grpc_listen_status));
             ("port", `Int grpc_port);
             ("service", `String Masc_grpc_service.service_name);
             ("health_service", `String Masc_grpc_server.health_service_name);
           ]
          @ if grpc_enabled then
              [ ("url", `String (Printf.sprintf "grpc://%s:%d" host grpc_port)) ]
            else
              []) );
      ("websocket", websocket_discovery_json ());
      ( "webrtc",
        `Assoc
          ([
             ("enabled", `Bool webrtc_enabled);
             ("signaling_path", `String "/webrtc");
             ("offer_path", `String "/webrtc/offer");
             ("answer_path", `String "/webrtc/answer");
             ( "ice_server_urls",
               `List
                 (List.map
                    (fun url -> `String url)
                    (Server_webrtc_transport.configured_ice_server_urls ())) );
             ("pending_offers", `Int (Server_webrtc_transport.pending_offer_count ()));
             ("active_peers", `Int (Server_webrtc_transport.active_peer_count ()));
             ("live_connections", `Int (Server_webrtc_transport.live_webrtc_count ()));
             ("connected_channels", `Int (Server_webrtc_transport.connected_channel_count ()));
           ]
          @ if webrtc_enabled then
              [ ("signaling_url", `String (base_url ^ "/webrtc")) ]
            else
              []) );
    ]

(* ================================================================ *)
(* Handlers                                                         *)
(* ================================================================ *)

let handle_transport_status _args : result =
  let json = transport_status_json () in
  (true, Yojson.Safe.pretty_to_string json)

let handle_websocket_discovery _args : result =
  let json = websocket_discovery_json () in
  (true, Yojson.Safe.pretty_to_string json)

let handle_webrtc_offer args : result =
  if not (Server_webrtc_transport.is_enabled ()) then
    error_result "webrtc transport disabled"
  else
  let*! agent_name = get_string_required args "agent_name" in
  let ice_candidates = get_string_list args "ice_candidates" in
  let fields =
    [
      ("agent_name", `String agent_name);
      ("ice_candidates", encode_string_list ice_candidates);
    ]
    @
    match get_string_opt args "dtls_fingerprint" with
    | Some fingerprint ->
        [ ("dtls_fingerprint", `String fingerprint) ]
    | None -> []
  in
  match
    Server_webrtc_transport.handle_offer_request
      (Yojson.Safe.to_string (`Assoc fields))
  with
  | Ok body -> (true, pretty_json_string body)
  | Error msg -> error_result msg

let handle_webrtc_answer args : result =
  if not (Server_webrtc_transport.is_enabled ()) then
    error_result "webrtc transport disabled"
  else
  let*! offer_id = get_string_required args "offer_id" in
  let*! agent_name = get_string_required args "agent_name" in
  let ice_candidates = get_string_list args "ice_candidates" in
  let body =
    `Assoc
      [
        ("offer_id", `String offer_id);
        ("agent_name", `String agent_name);
        ("ice_candidates", encode_string_list ice_candidates);
      ]
    |> Yojson.Safe.to_string
  in
  match Server_webrtc_transport.handle_answer_request body with
  | Ok response -> (true, pretty_json_string response)
  | Error msg -> error_result msg
