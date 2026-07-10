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

let websocket_scheme_for_http_scheme = function
  | Some scheme ->
    (match String.lowercase_ascii scheme with
     | "https" | "wss" -> "wss"
     | "http" | "ws" -> "ws"
     | _ -> "ws")
  | None -> "ws"
;;

let websocket_url_from_base_url base_url =
  let uri = Uri.of_string (trim_trailing_slashes base_url) in
  let uri =
    Uri.with_scheme uri (Some (websocket_scheme_for_http_scheme (Uri.scheme uri)))
  in
  (Uri.to_string uri |> trim_trailing_slashes) ^ "/ws"
;;

let configured_http_port () = Env_config_core.masc_http_port_int ()
let configured_http_host () = Env_config_core.masc_host ()

let ipaddr_is_unspecified = function
  | Ipaddr.V4 addr -> Ipaddr.V4.compare addr Ipaddr.V4.any = 0
  | Ipaddr.V6 addr -> Ipaddr.V6.compare addr Ipaddr.V6.unspecified = 0
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
  | _ -> (
      match Ipaddr.of_string normalized with
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

let get_ws_session_count () =
  match Transport_bridge.provider_by_name "ws" with
  | Some m ->
      let module M = (val m : Transport_bridge.PROVIDER) in
      M.session_count ()
  | None -> 0

let websocket_discovery_json (ctx : http_context) =
  let enabled = Transport_metrics.ws_enabled () in
  let state =
    if enabled
    then Transport_metrics.get_ws_upgrade_state ()
    else Transport_metrics.Disabled
  in
  let ready = state = Transport_metrics.Ready in
  let ws_url =
    if ready
    then `String (websocket_url_from_base_url ctx.base_url)
    else `Null
  in
  let unavailable_reason =
    match state with
    | Transport_metrics.Ready -> []
    | Transport_metrics.Initializing ->
      [ "unavailable_reason", `String "initializing" ]
    | Transport_metrics.Disabled ->
      [ "unavailable_reason", `String "disabled" ]
    | Transport_metrics.H2_only_unsupported ->
      [ "unavailable_reason", `String "h2_only_unsupported" ]
    | Transport_metrics.Stopped ->
      [ "unavailable_reason", `String "stopped" ]
  in
  let base_fields =
    [ "enabled", `Bool enabled ]
    @ maybe_configured_fields ~include_configured:ctx.include_configured enabled
    @ [ "listening", `Bool ready
      ; "reachable", `Bool ready
      ; ( "listen_status"
        , `String (Transport_metrics.ws_upgrade_state_to_string state) )
      ; "mode", `String "same_origin"
      ; "discovery_path", `String "/ws"
      ; "upgrade_path", `String "/ws"
      ; "request_host", `String ctx.host
      ; "ws_url", ws_url
      ; "session_count", `Int (get_ws_session_count ())
      ]
  in
  `Assoc (base_fields @ unavailable_reason)
;;

type webrtc_status =
  { ice_server_urls : string list
  ; pending_offers : int
  ; active_peers : int
  ; live_connections : int
  ; connected_channels : int
  }

let grpc_service_name = ref "MascGrpcService"
let grpc_health_service_name = ref "grpc.health.v1.Health"

let default_webrtc_status () =
  { ice_server_urls = []
  ; pending_offers = 0
  ; active_peers = 0
  ; live_connections = 0
  ; connected_channels = 0
  }

let webrtc_status_callback = ref default_webrtc_status

let register_grpc_service_name name = grpc_service_name := name
let register_grpc_health_service_name name = grpc_health_service_name := name
let register_webrtc_status fn = webrtc_status_callback := fn

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
  let grpc_enabled = Env_config.Transport.grpc_enabled () in
  let grpc_port = Env_config.Transport.grpc_port in
  let grpc_reachable =
    Transport_metrics.grpc_listening () || tcp_port_reachable grpc_port
  in
  let streamable_auth_policy_present =
    Env_config.Transport.http_auth_strict_env_enabled ()
  in
  let webrtc_enabled = Env_config.Transport.webrtc_enabled () in
  let w_status = !webrtc_status_callback () in
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
             ; "service", `String !grpc_service_name
             ; "health_service", `String !grpc_health_service_name
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
                      w_status.ice_server_urls) )
             ; "pending_offers", `Int w_status.pending_offers
             ; "active_peers", `Int w_status.active_peers
             ; "live_connections", `Int w_status.live_connections
             ; ( "connected_channels"
               , `Int w_status.connected_channels )
             ]
           @
           if webrtc_enabled
           then [ "signaling_url", `String (ctx.base_url ^ "/webrtc") ]
           else []) )
    ; "total_sessions", `Int (Transport_bridge.total_session_count ())
    ; "enabled_protocols", enabled_protocols_json ()
    ]
;;
