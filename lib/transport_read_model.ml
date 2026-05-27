type http_context =
  { base_url : string
  ; host : string
  ; include_configured : bool
  }

let trim_trailing_slashes value =
  (* Single-pass scan + at-most-one [String.sub], instead of recursing
     once per trailing '/'.  base_url normalization runs on every
     binding/handshake so even the small-N case adds up. *)
  let len = String.length value in
  let rec last_non_slash i =
    if i < 0 || value.[i] <> '/' then i else last_non_slash (i - 1)
  in
  let last = last_non_slash (len - 1) in
  if last = len - 1 then value else String.sub value 0 (last + 1)
;;

;;

let configured_http_port () = Env_config_core.masc_http_port_int ()
let configured_http_host () = Env_config_core.masc_host ()

let ipaddr_is_unspecified = function
  | Ipaddr.V4 addr -> Ipaddr.V4.compare addr Ipaddr.V4.any = 0
  | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0
;;

let ipaddr_is_loopback = function
  | Ipaddr.V4 addr ->
    let octets = Ipaddr.V4.to_octets addr in
    String.length octets = 4 && Char.code octets.[0] = 127
  | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0
;;

let is_unspecified_host host =
  match Ipaddr.of_string (String.trim host) with
  | Ok ip -> ipaddr_is_unspecified ip
  | Error _ -> false
;;

let is_canonical_loopback_alias host =
  let normalized = String.trim host |> String.lowercase_ascii in
  match normalized with
  | "localhost" -> true
  | _ ->
    (match Ipaddr.of_string normalized with
     | Ok (Ipaddr.V6 addr) -> Ipaddr.V6.compare addr Ipaddr.V6.localhost = 0
     | Ok (Ipaddr.V4 _) -> false
     | Error _ -> false)
;;

let normalize_advertised_host host =
  let trimmed = String.trim host in
  if is_unspecified_host trimmed || is_canonical_loopback_alias trimmed
  then Masc_network_defaults.masc_http_default_host
  else trimmed
;;

let normalize_loopback_base_url base_url =
  let trimmed = trim_trailing_slashes base_url in
  let uri = Uri.of_string trimmed in
  match Uri.host uri with
  | Some host ->
    let normalized_host = normalize_advertised_host host in
    if String.equal normalized_host host
    then trimmed
    else
      Uri.with_host uri (Some normalized_host) |> Uri.to_string |> trim_trailing_slashes
  | None -> trimmed
;;

let make_http_context
      ?(include_configured = false)
      ~base_url
      ~host
      ()
  =
  { base_url = normalize_loopback_base_url base_url
  ; host = normalize_advertised_host host
  ; include_configured
  }
;;

let context_from_env ?(include_configured = false) () =
  let default_host = configured_http_host () |> normalize_advertised_host in
  let default_base_url =
    Printf.sprintf "http://%s:%d" default_host (configured_http_port ())
  in
  let base_url =
    match Sys.getenv_opt Env_config_core.http_base_url_env_key with
    | Some raw ->
      (match String_util.trim_nonempty raw with
       | Some value -> normalize_loopback_base_url value
       | None -> default_base_url)
    | None -> default_base_url
  in
  let uri = Uri.of_string base_url in
  let host =
    match Uri.host uri with
    | Some value -> normalize_advertised_host value
    | None -> default_host
  in
  make_http_context ~include_configured ~base_url ~host ()
;;

let maybe_configured_fields ~include_configured enabled =
  if include_configured then [ "configured", `Bool enabled ] else []
;;

(* [tcp_port_reachable] used to open a stdlib [Unix.socket], call
   [Unix.connect] against the configured loopback host, and close the
   socket — all synchronously on the calling fiber's Eio domain.

   That implementation is incompatible with Eio's cooperative
   scheduling: from the official docs,

     "When a fiber executes CPU-bound or blocking I/O work without
      yielding control, it blocks all other fibers in that domain."

   The probe was wired into every /health response builder
   ([websocket_discovery_json], [transport_status_json]) where it
   short-circuits behind [Transport_metrics.{ws,grpc}_listening].
   Under normal operation the listening flag is [true] and the
   stdlib call never runs.  But during startup / warm-up the
   listening flag is [false] and every concurrent /health probe
   queued waiting for a blocking [Unix.connect], stalling every
   other fiber on the main Eio HTTP domain for the duration of the
   connect.  Concurrent dashboard requests saw this as multi-second
   latency cliffs at startup.

   Fix: drop the blocking probe entirely.  Callers already OR with
   the in-memory listening flag, so:

   - listening = true  → reachable = true   (unchanged)
   - listening = false → reachable = false  (warming up, accurate)

   The latter is the truthful state during warm-up — a listener that
   has not bound the socket yet is not reachable.  The previous
   implementation could only have flipped this to [true] by racing
   against another listener binding the same port, which is not a
   useful signal.

   Argument kept for API stability; callers still pass [port] from
   the relevant configured-port lookup but the value is unused. *)
let tcp_port_reachable (_port : int) : bool = false
;;

let websocket_discovery_json (ctx : http_context) =
  let enabled = Server_ws_standalone.is_enabled () in
  let port = Server_ws_standalone.configured_port () in
  let reachable = Transport_metrics.ws_listening () || tcp_port_reachable port in
  let base_fields =
    [ "enabled", `Bool enabled ]
    @ maybe_configured_fields ~include_configured:ctx.include_configured enabled
    @ [ "listening", `Bool (Transport_metrics.ws_listening ())
      ; "reachable", `Bool reachable
      ; "listen_status", `String (Atomic.get Transport_metrics.ws_listen_status)
      ; "mode", `String "standalone"
      ; "discovery_path", `String "/ws"
      ; "session_count", `Int (Server_mcp_transport_ws.session_count ())
      ]
  in
  let fields =
    if enabled
    then
      base_fields
      @ [ "ws_port", `Int port
        ; "ws_url", `String (Printf.sprintf "ws://%s:%d/" ctx.host port)
        ]
    else base_fields
  in
  `Assoc fields
;;

let enabled_protocols_json () =
  let protocols =
    List.fold_left
      (fun acc protocol -> if List.mem protocol acc then acc else acc @ [ protocol ])
      [ Transport.JsonRpc ]
      (Transport_bridge.enabled_protocols ())
  in
  `List
    (List.map (fun protocol -> `String (Transport.protocol_to_string protocol)) protocols)
;;

let transport_status_json (ctx : http_context) =
  let grpc_enabled = Masc_grpc_server.is_enabled () in
  let grpc_port = Masc_grpc_server.configured_port () in
  let grpc_reachable =
    Transport_metrics.grpc_listening () || tcp_port_reachable grpc_port
  in
  let streamable_auth_policy_present =
    Env_config.Transport.http_auth_strict_env_enabled ()
  in
  let webrtc_enabled = Server_webrtc_transport.is_enabled () in
  `Assoc
    [ "streamable_http_default", `Bool true
    ; "legacy_endpoints_deprecated", `Bool true
    ; ( "http"
      , `Assoc
          (maybe_configured_fields ~include_configured:ctx.include_configured true
           @ [ "enabled", `Bool true
             ; "protocol_capable", `Bool true
             ; "auth_policy_present", `Bool streamable_auth_policy_present
             ; "base_url", `String ctx.base_url
             ; "mcp_url", `String (ctx.base_url ^ "/mcp")
             ; "sse_url", `String (ctx.base_url ^ "/mcp?sse_kind=observer")
             ]) )
    ; ( "grpc"
      , `Assoc
          ([ "enabled", `Bool grpc_enabled ]
           @ maybe_configured_fields
               ~include_configured:ctx.include_configured
               grpc_enabled
           @ [ "listening", `Bool (Transport_metrics.grpc_listening ())
             ; "reachable", `Bool grpc_reachable
             ; "listen_status", `String (Atomic.get Transport_metrics.grpc_listen_status)
             ; "port", `Int grpc_port
             ; "service", `String Masc_grpc_service.service_name
             ; "health_service", `String Masc_grpc_server.health_service_name
             ]
           @
           if grpc_enabled
           then [ "url", `String (Printf.sprintf "grpc://%s:%d" ctx.host grpc_port) ]
           else []) )
    ; "websocket", websocket_discovery_json ctx
    ; ( "webrtc"
      , `Assoc
          ([ "enabled", `Bool webrtc_enabled ]
           @ maybe_configured_fields
               ~include_configured:ctx.include_configured
               webrtc_enabled
           @ [ "signaling_available", `Bool webrtc_enabled
             ; "signaling_mode", `String "shared_http"
             ; "signaling_path", `String "/webrtc"
             ; "offer_path", `String "/webrtc/offer"
             ; "answer_path", `String "/webrtc/answer"
             ; ( "ice_server_urls"
               , `List
                   (List.map
                      (fun url -> `String url)
                      (Server_webrtc_transport.configured_ice_server_urls ())) )
             ; "pending_offers", `Int (Server_webrtc_transport.pending_offer_count ())
             ; "active_peers", `Int (Server_webrtc_transport.active_peer_count ())
             ; "live_connections", `Int (Server_webrtc_transport.live_webrtc_count ())
             ; ( "connected_channels"
               , `Int (Server_webrtc_transport.connected_channel_count ()) )
             ]
           @
           if webrtc_enabled
           then [ "signaling_url", `String (ctx.base_url ^ "/webrtc") ]
           else []) )
    ; "total_sessions", `Int (Transport_bridge.total_session_count ())
    ; "enabled_protocols", enabled_protocols_json ()
    ]
;;
