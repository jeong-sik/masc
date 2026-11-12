(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Http = Http_server_eio
module M = Authz_boot_mode_read
module Table = Server_account_table

let ( let* ) = Result.bind
let ms_per_second = 1000.

type refusal =
  | Http_mode_refused of string
  | Zone_not_opened of Authz_zone.open_error
  | Zone_not_trusted of Authz_zone.uncertain
  | Zone_not_multi_account of Authz_mode_state.t
  | Login_client_refused of Server_account_login.refusal
  | Route_of_another_kind of Table.refusal
  | Https_listener_refused of string
  | Listener_not_bound of
      { host : string
      ; port : int
      ; reason : string
      }
  | Trust_policy_refused of Server_request_authority.trust_policy_error
  | Port_not_announced of Server_startup_takeover.base_path_lock_rejection
  | Access_not_published of Runtime_account_access.publish_error

let refusal_to_string = function
  | Http_mode_refused reason -> reason
  | Zone_not_opened error ->
    "the authorization zone is not opened: " ^ Authz_zone.open_error_to_string error
  | Zone_not_trusted uncertain ->
    "the authorization zone changed since the boot judged it, and cannot be trusted \
     (AuthorizationUncertain): "
    ^ Authz_zone.uncertain_detail uncertain
  | Zone_not_multi_account mode ->
    Printf.sprintf
      "the authorization log changed since the boot judged it Multi_account: its mode is now %s"
      (Authz_mode_state.to_string mode)
  | Login_client_refused refusal -> Server_account_login.refusal_to_string refusal
  | Route_of_another_kind refusal -> Table.refusal_to_string refusal
  | Https_listener_refused reason -> "HTTPS listener: " ^ reason
  | Listener_not_bound { host; port; reason } ->
    Printf.sprintf "%s:%d is not listened on: %s" host port reason
  | Trust_policy_refused error -> Server_request_authority.trust_policy_error_to_string error
  | Port_not_announced rejection ->
    "the port is not announced to the host, so no command could replace this server: "
    ^ Server_startup_takeover.base_path_lock_rejection_to_string rejection
  | Access_not_published error -> Runtime_account_access.publish_error_to_string error
;;

(* The release version and the mode, and nothing of the host or the
   workspace: the answer goes to anyone who reaches the listener.
   [Build_identity.to_yojson] is not part of it, because it carries the path
   of the executable and of its checkout, the commit, and when the process
   started. *)
let health_server_field = "server"
let health_version_field = "version"
let health_account_mode_field = "account_mode"
let health_server_name = "masc"
let health_account_mode = Masc_domain.account_mode_label Masc_domain.Multi_account

let health (_ : Httpun.Request.t) reqd =
  Http.Response.json_value
    (`Assoc
       [ health_server_field, `String health_server_name
       ; health_version_field, `String Runtime_build_version.current
       ; health_account_mode_field, `String health_account_mode
       ])
    reqd
;;

(* The release version in an answer of [health], for a command line that
   names the server it is about to replace. Any other body is [None]. *)
let health_version body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error _ -> None
  | `Assoc fields ->
    (match
       ( List.assoc_opt health_server_field fields
       , List.assoc_opt health_account_mode_field fields
       , List.assoc_opt health_version_field fields )
     with
     | Some (`String server), Some (`String mode), Some (`String version)
       when String.equal server health_server_name && String.equal mode health_account_mode ->
       Some version
     | _ -> None)
  | _ -> None
;;

(* The listener answers. Nothing of the process or of the host. *)
let liveness (_ : Httpun.Request.t) reqd =
  Http.Response.json_value (`Assoc [ "live", `Bool true ]) reqd
;;

(* Ready while a decision can rest on the zone: without that every route of a
   person is a 503 ([Login_routes.zone_uncertain]). The reason names paths of
   the server, so the probe says only that the server is not ready. *)
let readiness zone (_ : Httpun.Request.t) reqd =
  match Authz_zone.read zone with
  | Ok (_ : Authz_zone.trusted) -> Http.Response.json_value (`Assoc [ "ready", `Bool true ]) reqd
  | Error (_ : Authz_zone.uncertain) ->
    Http.Response.json_value
      ~status:`Service_unavailable
      (`Assoc [ "ready", `Bool false ])
      reqd
;;

let register ~login ~env ~base_path zone router =
  router
  |> Server_route.get Server_route.Always_public Server_health_paths.health health
  |> Server_route.get Server_route.Always_public Server_health_paths.liveness liveness
  |> Server_route.get Server_route.Always_public Server_health_paths.readiness (readiness zone)
  |> Server_login_http.add_routes login
  |> Server_login_http.add_person_routes login ~env ~base_path
;;

(* A value of the HTTP mode that is not in its vocabulary stops the boot here,
   before [run] opens a file or binds a port. *)
let http_mode () =
  match Env_config.Transport.configure_h2_from_env () with
  | mode -> Ok mode
  | exception Env_config_core.Config_error reason -> Error (Http_mode_refused reason)
;;

(* The zone that is served is the one the boot judged. The judgment read the
   files and the zone read them again when it opened: a file that changed
   between the two leaves a zone that cannot be trusted, or a log in another
   mode, and the boot stops. The install record and config.json are not read
   again: the zone is opened over the store path the judgment read, and the
   mode is the mode of the log. *)
let judged_again zone =
  match Authz_zone.read zone with
  | Error uncertain -> Error (Zone_not_trusted uncertain)
  | Ok trusted ->
    (match (trusted :> Authz_zone.snapshot).Authz_zone.state.Authz_state.mode with
     | Authz_mode_state.Multi_account (_ : Authz_types.Workspace_id.t) -> Ok ()
     | (Authz_mode_state.Not_bootstrapped | Authz_mode_state.Off (_ : Authz_types.Workspace_id.t))
       as mode -> Error (Zone_not_multi_account mode))
;;

(* The port the CLI of the workspace reads when none is given
   ([Workspace_connection.resolve]): what was asked for, not a readiness. *)
let record_port ~base_path (config : Http.config) =
  match Workspace_connection.port config.port with
  | Error error -> Log.Server.warn "%s" (Workspace_connection.error_message error)
  | Ok port ->
    (match Workspace_connection.save ~base_path ~port with
     | Ok () -> ()
     | Error error -> Log.Server.warn "%s" (Workspace_connection.error_message error))
;;

let serve ~sw ~clock ~http_mode ~(config : Http.config) ~socket ~https_listener ~trust_policy table =
  let request_handler = Server_http_ingress.http1_table_handler ~trust_policy table in
  let h2_request_handler = Server_h2_gateway.make_table_request_handler ~trust_policy ~table in
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
  match http_mode with
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

let run ~sw ~env ~address ~port ~lease ?on_ready multi_account =
  let clock = Eio.Stdenv.clock env in
  let net = Eio.Stdenv.net env in
  let base_path = M.multi_account_base_path multi_account in
  let* http_mode = http_mode () in
  let* zone =
    Result.map_error
      (fun error -> Zone_not_opened error)
      (Authz_zone.open_at_start
         ~now_ms:(fun () -> int_of_float (Eio.Time.now clock *. ms_per_second))
         ~log_path:(Authz_log.path_of_base_path ~base_path)
         ~store_path:(M.multi_account_external_store multi_account))
  in
  let* () = judged_again zone in
  let* login_clients =
    Result.map_error
      (fun refusal -> Login_client_refused refusal)
      (Server_account_login.clients_of_config
         ~getenv:Sys.getenv_opt
         (M.multi_account_login_clients multi_account))
  in
  (match login_clients with
   | { Server_account_login.google = None; github = None } ->
     Log.Server.warn
       "config.json names no login client (google, github): the login routes answer 404 and \
        nobody logs in"
   | { Server_account_login.google = Some _; github = Some _ | None }
   | { Server_account_login.google = None; github = Some _ } -> ());
  let login = Server_account_login.routes ~clock ~zone login_clients in
  let* table =
    Result.map_error
      (fun refusal -> Route_of_another_kind refusal)
      (Table.checked (register ~login ~env ~base_path zone))
  in
  (* Read before [make_http_config], which writes the address the listener
     binds into this variable when the operator left it unset: after it, a
     base URL of the operator and that address read the same. *)
  let operator_base_url = Env_config_core.masc_http_base_url_opt () in
  let config = Server_bootstrap_http.make_http_config ~address ~port in
  let* https =
    Result.map_error
      (fun reason -> Https_listener_refused reason)
      (Server_bootstrap_http.https_listener_of_env ~base_path ~bind_host:config.host)
  in
  (* The port is bound here and accepted on in [serve], below. *)
  let* socket =
    Result.map_error
      (fun reason -> Listener_not_bound { host = config.host; port = config.port; reason })
      (Server_bootstrap_http.listen_socket_result ~sw ~net ~address config)
  in
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
  let* () =
    match
      Server_account_login.redirects_on_the_server
        ~base_url:
          (* [make_http_config] keeps a base URL that is set, so the
             identity the policy projects is the operator's. *)
          (Option.map
             (fun (_ : string) -> Server_request_authority.projection_context trust_policy)
             operator_base_url)
        login_clients
    with
    | Error refusal -> Error (Login_client_refused refusal)
    | Ok Server_account_login.Compared_with_the_base_url -> Ok ()
    | Ok Server_account_login.No_base_url ->
      (match login_clients with
       | { Server_account_login.google = None; github = None } -> ()
       | { Server_account_login.google = Some _; github = Some _ | None }
       | { Server_account_login.google = None; github = Some _ } ->
         Log.Server.info
           "%s is not set: the redirect_uri of a login client is not compared with the address \
            of this server"
           Env_config_core.http_base_url_env_key);
      Ok ()
  in
  (* The host reads the port of this server from the kernel
     ([Server_startup_takeover.announce_account_server]). The probes say
     nothing of the workspace, so [masc restart] stops only an owner that
     announces the port it was asked about, and takes a replacement for
     ready only once it announces. A server that cannot announce could not
     be replaced by a command, so its boot stops.

     It comes after every check that can stop a boot: a command that reads
     the announcement reads a server that goes on to serve. The one step
     after it that can refuse is the publication, which refuses a process
     that published before, and a boot publishes once. *)
  let* () =
    Result.map_error
      (fun rejection -> Port_not_announced rejection)
      (Server_startup_takeover.announce_account_server lease ~port:config.port)
  in
  let* () =
    Result.map_error
      (fun error -> Access_not_published error)
      (Runtime_account_access.publish
         (Runtime_account_access.Multi_account
            { zone; base_path; now = (fun () -> Eio.Time.now clock) }))
  in
  (* Nothing below refuses: a boot that stops records no port and leaves no
     fiber behind. *)
  (* A login reaches its provider over [Masc_http_client], which makes its
     connections from the environment and under the switch of the process
     ([Eio_context]). The single-user boot sets the two in its owner state,
     which this server does not build. *)
  Eio_context.set_env env;
  Eio_context.set_switch sw;
  record_port ~base_path config;
  Rate_limit.start_global_cleanup_loop ~sw ~clock;
  Log.Server.info
    "the account server of the multi-account installation listens on %s:%d (https port %s); it \
     serves the %d route(s) of its own table, and no route that reads the credentials of a \
     single user"
    config.host
    config.port
    (match https_port with
     | Some port -> string_of_int port
     | None -> "off")
    (Table.route_count table);
  Option.iter (fun on_ready -> on_ready ()) on_ready;
  serve ~sw ~clock ~http_mode ~config ~socket ~https_listener ~trust_policy table;
  Ok ()
;;
