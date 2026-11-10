(* HIGH-RISK-UNREVIEWED: the server of a multi-account installation. Every
   route of its table can be called by anyone who reaches the listener, so a
   route that is added here is open to every person of the installation and to
   everyone else on the network. *)

(** The server of an active multi-account installation (multi-account plan,
    S1a).

    A boot that judges a base path [Multi_account]
    ({!Authz_boot_mode_read.boot}) runs this server and not the owner state of
    a single user. This server builds no [Mcp_server.server_state], starts no
    Keeper, and registers none of the routes whose wrappers read the
    credentials of a single user ([Server_auth]). A request for one of those
    routes is the 404 of the router.

    What the two servers share: the listener code ({!Server_bootstrap_http}),
    the admission of the Host and of the Origin of a request and the limit
    per client address ({!Server_http_ingress}), whose state is one per
    process, and the HTTP configuration of the environment (the HTTP mode,
    the HTTPS port, the base URL).

    {b The table.} {!register} is everything the server answers. A route is
    [Always_public], or it authenticates the request in its own code against
    the authorization zone ([Self_authenticated Browser_session]).
    {!run} makes the table with {!Server_account_table.checked} before it
    listens ({!Route_of_another_kind}), so a registration of another kind
    stops the boot and is not served.

    This layer registers the three health probes. The login routes and the
    routes of a person come with the layers after it.

    {b The probes.} They are answered to anyone who reaches the listener and
    say nothing of the host or of the process.
    - [GET /health]: the server name, the release version and the account
      mode.
    - [GET /health/live]: [{"live": true}] once the listener answers.
    - [GET /health/ready]: [{"ready": true}] while a decision can rest on the
      authorization zone ({!Authz_zone.read}), and a 503 with
      [{"ready": false}] otherwise. Every route of a person is a 503 in that
      state, so the server is taken out of service by whatever reads the
      probe.

    {b The zone.} {!run} opens the authorization zone over the log of the base
    path and the external store that the boot judgment read, and reads it
    once more: a file that changed between the judgment and the opening
    leaves a zone that cannot be trusted or a log in another mode, and the
    boot stops ({!Zone_not_trusted}, {!Zone_not_multi_account}). It publishes
    the access of the process ({!Runtime_account_access.Multi_account}) before
    it accepts a connection, so no CLI starts on an account without the
    decision of the log. *)

type refusal =
  | Http_mode_refused of string
      (** The HTTP mode of the environment is not in its vocabulary
          ({!Env_config.Transport.configure_h2_from_env}). *)
  | Zone_not_opened of Authz_zone.open_error
  | Zone_not_trusted of Authz_zone.uncertain
      (** The zone that opened cannot be trusted: the store or the log changed
          after the boot judged them. *)
  | Zone_not_multi_account of Authz_mode_state.t
      (** The log that opened is not in the mode the boot judged. *)
  | Route_of_another_kind of Server_account_table.refusal
      (** The table holds a route that is neither [Always_public] nor
          [Self_authenticated Browser_session]. *)
  | Https_listener_refused of string
      (** {!Server_bootstrap_http.https_listener_of_env} refused. *)
  | Listener_not_bound of
      { host : string
      ; port : int
      ; reason : string
      }  (** The cleartext listener did not bind, for example a port in use. *)
  | Access_not_published of Runtime_account_access.publish_error
  | Trust_policy_refused of Server_request_authority.trust_policy_error

val refusal_to_string : refusal -> string

(** Registers the routes of the account server over [zone]. *)
val register : Authz_zone.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

(** Reads the HTTP mode, opens the zone and reads it again, makes the table,
    binds [address]:[port], publishes the access, binds the HTTPS listener of
    the environment, records the port for the CLI of the workspace
    ([Workspace_connection]), calls [on_ready], and serves until [sw] is
    cancelled. The cleartext listener follows the HTTP mode of the
    environment, as the single-user server does.

    An [Error] comes before a connection is accepted and before the port is
    recorded, and the refusals come in the order of the constructors of
    {!refusal}. {!Access_not_published} and {!Trust_policy_refused} come with
    the port bound: the trust policy names the HTTPS port that bound. *)
val run
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> address:Ipaddr.t
  -> port:int
  -> ?on_ready:(unit -> unit)
  -> Authz_boot_mode_read.multi_account
  -> (unit, refusal) result
