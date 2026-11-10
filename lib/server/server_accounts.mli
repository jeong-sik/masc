(* HIGH-RISK-UNREVIEWED: the server of a multi-account installation. Every
   route of its table can be called by anyone who reaches the listener, so a
   route that is added here is open to every person of the installation and to
   everyone else on the network. *)

(** The server of an active multi-account installation (multi-account plan,
    S1a).

    A boot that judges a base path [Multi_account]
    ({!Authz_boot_mode_read.boot}) runs this server and not the owner state of
    a single user. The two share the listener code and nothing else: this
    server builds no [Mcp_server.server_state], starts no Keeper, and
    registers none of the routes of the single-user server, whose wrappers
    read the credentials of a single user ([Server_auth]). A request for one
    of those routes is the 404 of the router.

    {b The table.} {!routes} is everything the server answers. A route is
    [Always_public], or it authenticates the request in its own code against
    the authorization zone ([Self_authenticated Browser_session]).
    {!run} checks the table before it listens ({!Route_of_another_kind}), so a
    registration of another kind stops the boot and is not served.

    This layer registers [GET /health] alone. The login routes and the routes
    of a person come with the layers after it.

    {b The zone.} {!run} opens the authorization zone over the log of the base
    path and the external store that the boot judgment read, and publishes the
    access of the process ({!Runtime_account_access.Multi_account}) before it
    listens, so no CLI starts on an account without the decision of the log. *)

type refusal =
  | Zone_not_opened of Authz_zone.open_error
  | Access_not_published of Runtime_account_access.publish_error
  | Route_of_another_kind of
      { path : string
      ; access : Route_access.t
      }
      (** The table holds a route that is neither [Always_public] nor
          [Self_authenticated Browser_session]. *)
  | Https_listener_refused of string
      (** {!Server_bootstrap_http.https_listener_of_env} refused. *)
  | Trust_policy_refused of Server_request_authority.trust_policy_error

val refusal_to_string : refusal -> string

(** The table of the account server. *)
val routes : unit -> Http_server_eio.Router.t

(** The first route of the table that the account server does not serve, as
    the refusal of {!run}. [None] for {!routes}. *)
val route_of_another_kind : Http_server_eio.Router.t -> refusal option

(** Opens the zone, publishes the access, binds [address]:[port] and the
    HTTPS listener of the environment, calls [on_ready], and serves until [sw]
    is cancelled. The cleartext listener follows the HTTP mode of the
    environment ({!Env_config.Transport.configure_h2_from_env}), as the
    single-user server does. An [Error] comes before anything is served. *)
val run
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> address:Ipaddr.t
  -> port:int
  -> ?on_ready:(unit -> unit)
  -> Authz_boot_mode_read.multi_account
  -> (unit, refusal) result
