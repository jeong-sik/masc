(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Http = Http_server_eio
module M = Authz_boot_mode_read

let ( let* ) = Result.bind
let ms_per_second = 1000.

type refusal =
  | Zone_not_opened of Authz_zone.open_error
  | Access_not_published of Runtime_account_access.publish_error
  | Route_of_another_kind of
      { path : string
      ; access : Route_access.t
      }
  | Https_listener_refused of string
  | Trust_policy_refused of Server_request_authority.trust_policy_error

let refusal_to_string = function
  | Zone_not_opened error ->
    "the authorization zone is not opened: " ^ Authz_zone.open_error_to_string error
  | Access_not_published error -> Runtime_account_access.publish_error_to_string error
  | Route_of_another_kind { path; access } ->
    Printf.sprintf
      "the route %s is registered as %s, and the account server serves only routes that are \
       public or that authenticate a browser session themselves"
      path
      (Yojson.Safe.to_string (Route_access.to_json access))
  | Https_listener_refused reason -> "HTTPS listener: " ^ reason
  | Trust_policy_refused error -> Server_request_authority.trust_policy_error_to_string error
;;

(* The release version and the mode, and nothing of the host or the
   workspace: the answer goes to anyone who reaches the listener.
   [Build_identity.to_yojson] is not part of it, because it carries the path
   of the executable and of its checkout, the commit, and when the process
   started. *)
let health (_ : Httpun.Request.t) reqd =
  Http.Response.json_value
    (`Assoc
       [ "server", `String "masc"
       ; "version", `String Runtime_build_version.current
       ; ( "account_mode"
         , `String (Masc_domain.account_mode_label Masc_domain.Multi_account) )
       ])
    reqd
;;

let routes () =
  Http.Router.create ()
  |> Server_route.get Server_route.Always_public Server_health_paths.health health
;;

(* Every other kind is applied through a wrapper of [Server_auth], which
   reads the credentials of a single user. *)
let served : Route_access.t -> bool = function
  | Route_access.Always_public
  | Route_access.Self_authenticated Route_access.Browser_session -> true
  | Route_access.Public_read
      (Route_access.Credential_when_strict | Route_access.Open_when_strict)
  | Route_access.Read_auth
  | Route_access.Permission (_ : Masc_domain.permission)
  | Route_access.Token_permission (_ : Masc_domain.permission)
  | Route_access.Private_token_permission (_ : Masc_domain.permission)
  | Route_access.Tool { tool_name = _ }
  | Route_access.Tool_observation { tool_name = _ }
  | Route_access.Tool_actor { tool_name = _ }
  | Route_access.Manage_own_provider
  | Route_access.Manage_own_keeper
  | Route_access.Self_authenticated
      ( Route_access.Mcp_transport
      | Route_access.Oauth_protocol
      | Route_access.Websocket_upgrade
      | Route_access.Loopback_dev_token
      | Route_access.Subpath_dispatch ) -> false
;;

let route_of_another_kind router =
  List.find_map
    (fun (route : Http.Router.route) ->
      if served route.access
      then None
      else Some (Route_of_another_kind { path = route.path; access = route.access }))
    (Http.Router.routes router)
;;

let checked_routes () =
  let router = routes () in
  match route_of_another_kind router with
  | Some refusal -> Error refusal
  | None -> Ok router
;;

let serve ~sw ~clock ~(config : Http.config) ~socket ~https_listener ~trust_policy router =
  let request_handler = Server_http_ingress.http1_table_handler ~trust_policy router in
  let h2_request_handler = Server_h2_gateway.make_table_request_handler ~trust_policy ~router in
  let h2_error_handler = Server_h2_gateway.make_error_handler () in
  Option.iter
    (fun ((https : Server_bootstrap_http.https_listener), https_socket) ->
      Eio.Fiber.fork ~sw (fun () ->
        Server_bootstrap_http.serve_tls
          ~sw
          ~clock
          ~socket:https_socket
          ~addr_label:(Printf.sprintf "%s:%d" config.host https.https_port)
          ~tls:https.tls
          ~request_handler
          ~h2_request_handler
          ~h2_error_handler))
    https_listener;
  let addr_label = Printf.sprintf "%s:%d" config.host config.port in
  match Env_config.Transport.configure_h2_from_env () with
  | Env_config.Transport.H2_only ->
    Server_bootstrap_http.serve_h2 ~sw ~clock ~socket ~addr_label ~h2_request_handler ~h2_error_handler
  | Env_config.Transport.H1_only ->
    Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label ~request_handler
  | Env_config.Transport.Auto ->
    Server_bootstrap_http.serve_auto
      ~sw
      ~clock
      ~socket
      ~addr_label
      ~request_handler
      ~h2_request_handler
      ~h2_error_handler
;;

let run ~sw ~env ~address ~port ?on_ready multi_account =
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  let base_path = M.multi_account_base_path multi_account in
  let* router = checked_routes () in
  let* zone =
    Result.map_error
      (fun error -> Zone_not_opened error)
      (Authz_zone.open_at_start
         ~now_ms:(fun () -> int_of_float (Eio.Time.now clock *. ms_per_second))
         ~log_path:(Authz_log.path_of_base_path ~base_path)
         ~store_path:(M.multi_account_external_store multi_account))
  in
  let* () =
    Result.map_error
      (fun error -> Access_not_published error)
      (Runtime_account_access.publish
         (Runtime_account_access.Multi_account
            { zone; base_path; now = (fun () -> Eio.Time.now clock) }))
  in
  let config = Server_bootstrap_http.make_http_config ~address ~port in
  let* https =
    Result.map_error
      (fun reason -> Https_listener_refused reason)
      (Server_bootstrap_http.https_listener_of_env ~base_path ~bind_host:config.host)
  in
  Rate_limit.start_global_cleanup_loop ~sw ~clock;
  let socket = Server_bootstrap_http.listen_socket ~sw ~net ~address config in
  let https_listener =
    Server_bootstrap_http.listen_https_socket ~sw ~net ~address ~config https
  in
  (* The port of the TLS listener that bound, as the single-user server
     reads it: a configured port that did not bind is no trusted identity. *)
  let https_port =
    Option.map
      (fun ((listener : Server_bootstrap_http.https_listener), _socket) -> listener.https_port)
      https_listener
  in
  let* trust_policy =
    Result.map_error
      (fun error -> Trust_policy_refused error)
      (Server_request_authority.make_trust_policy
         ~bind_host:config.host
         ~bind_port:config.port
         ~https_port
         ~explicit_base_url:(Env_config_core.masc_http_base_url_opt ()))
  in
  Log.Server.info
    "the account server of the multi-account installation listens on %s:%d (https port %s); it \
     serves %d route(s), and none of the single-user server"
    config.host
    config.port
    (match https_port with
     | Some port -> string_of_int port
     | None -> "off")
    (Http.Router.route_count router);
  Option.iter (fun on_ready -> on_ready ()) on_ready;
  serve ~sw ~clock ~config ~socket ~https_listener ~trust_policy router;
  Ok ()
;;
