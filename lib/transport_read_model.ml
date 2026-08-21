type http_context =
  { base_url : string
  ; host : string
  ; include_configured : bool
  }

let trim_trailing_slashes = Masc_network_defaults.trim_trailing_slashes
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

let get_ws_session_count () =
  match Transport_bridge.provider_by_name "ws" with
  | Some m ->
      let module M = (val m : Transport_bridge.PROVIDER) in
      M.session_count ()
  | None -> 0

(* WebSocket is served only as a same-origin upgrade on the HTTP
   listener, so readiness is exactly [ws_enabled ()]:
   [set_ws_same_origin_runtime_ready true] runs unconditionally in
   [Server_runtime_bootstrap] before any transport starts. There is no
   separate host/port for a client to discover — the socket is the one
   it already reached us on. *)
let websocket_discovery_json (ctx : http_context) =
  let enabled = Transport_metrics.ws_enabled () in
  let ready = Transport_metrics.ws_same_origin_ready () in
  let same_origin_ws_url = websocket_url_from_base_url ctx.base_url in
  let base_fields =
    [ "enabled", `Bool enabled ]
    @ maybe_configured_fields ~include_configured:ctx.include_configured enabled
    @ [ "listening", `Bool ready
      ; "reachable", `Bool ready
      ; "mode", `String "same_origin"
      ; "discovery_path", `String "/ws"
      ; "upgrade_path", `String "/ws"
      ; "request_host", `String ctx.host
      ; "session_count", `Int (get_ws_session_count ())
      ]
  in
  let fields =
    if enabled
    then
      base_fields
      @ [ (* Withheld until the inbound dispatcher is installed: a client
             that connects before then gets an upgrade with no handler. *)
          "ws_url", (if ready then `String same_origin_ws_url else `Null)
        ; "same_origin_upgrade_enabled", `Bool ready
        ; "same_origin_upgrade_path", `String "/ws"
        ; "same_origin_ws_url", `String same_origin_ws_url
        ]
    else base_fields
  in
  `Assoc fields
;;

type runtime_registrations =
  { grpc_service_name : string
  ; grpc_health_service_name : string
  }

let runtime_registrations =
  Atomic.make
    { grpc_service_name = "MascGrpcService"
    ; grpc_health_service_name = "grpc.health.v1.Health"
    }

let register_grpc_service_name name =
  Atomic_util.update runtime_registrations (fun current ->
    { current with grpc_service_name = name })

let register_grpc_health_service_name name =
  Atomic_util.update runtime_registrations (fun current ->
    { current with grpc_health_service_name = name })

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
  let registrations = Atomic.get runtime_registrations in
  let grpc_enabled = Env_config.Transport.grpc_enabled () in
  let grpc_port = Env_config.Transport.grpc_port in
  let grpc_reachable = Transport_metrics.grpc_listening () in
  let streamable_auth_policy_present =
    Env_config.Transport.http_auth_strict_env_enabled ()
  in
  `Assoc
    [ "streamable_http_default", `Bool true
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
             ; "service", `String registrations.grpc_service_name
             ; "health_service", `String registrations.grpc_health_service_name
             ]
           @
           if grpc_enabled
           then [ "url", `String (Printf.sprintf "grpc://%s:%d" ctx.host grpc_port) ]
           else []) )
    ; "websocket", websocket_discovery_json ctx
    ; "total_sessions", `Int (Transport_bridge.total_session_count ())
    ; "enabled_protocols", enabled_protocols_json ()
    ]
;;
