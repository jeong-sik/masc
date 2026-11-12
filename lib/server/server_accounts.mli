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

    {b The table.} The routes this module registers are everything the
    server answers. A route is
    [Always_public], or it authenticates the request in its own code against
    the authorization zone ([Self_authenticated Browser_session], and
    [Self_authenticated Person_mcp] for the MCP endpoint of a person).
    {!run} makes the table with {!Server_account_table.checked} before it
    listens ({!Route_of_another_kind}), so a registration of another kind
    stops the boot and is not served.

    The table holds the three health probes, the login routes
    ({!Server_login_http.add_routes}): the start and the callback of a
    Google and of a GitHub login, the logout, the session, the allowlist and
    the personal access tokens, and the pages and routes of a person
    ({!Server_login_http.add_person_routes}): the home page and the page
    of an invitation, who-am-I, the person's subscriptions and their
    connection, the person's Keepers, and one turn of a Keeper on the
    Runtime its owner gave it. A turn starts the official client of the
    person's own subscription, on the home of that account, as a process of
    the server ({!Server_preview_keeper_turn}).

    It also holds the console of a signed-in person
    ({!Server_account_console.add_routes}): the page, the files of its build
    and the sheet it shares with the pages above. The page and the files come
    from the dashboard bundle of the server and the sheet from the binary;
    all three are answered with no credential. The rest of the bundle, the
    operator dashboard among it, is not answered.
    When the bundle cannot give the page, the page is a 503, the boot says
    why in the log, and every other route answers as it does without it.

    {b The login clients.} They are the [google] and the [github] member of
    the [config.json] that the boot judged
    ({!Authz_boot_mode_read.multi_account_login_clients}); the file is not
    read again. A client is built by {!Login_client.of_environment}: its
    secret is read from the environment variable the member names, and its
    redirect is an [https] URL. A member whose client is refused stops the
    boot ({!Login_client_refused}). A provider with no member is not
    configured, and its start and its callback answer 404; with neither
    member nobody logs in, and the boot says so in the log. A redirect whose
    path is not the callback of its provider stops the boot too
    ({!Server_account_login.Redirect_not_the_callback}). When the operator
    configured the base URL of the server ([MASC_HTTP_BASE_URL]), a redirect
    whose origin (scheme, host and port) is not that of the base URL stops
    the boot as well ({!Server_account_login.Redirect_not_on_the_base_url}).
    Without a base URL the server knows no public address of its own: it
    compares nothing and says so in the log, and a redirect that names
    another host fails at the provider or at the callback of the first
    login.

    {b The probes.} They are answered with no credential, to a request whose
    Host is an identity of the server ({!Server_http_ingress.serve_table}),
    and say nothing of the host or of the process.
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
    boot stops ({!Zone_not_trusted}, {!Zone_not_multi_account}). A store that
    is gone is not opened ({!Zone_not_opened}). The install record and
    [config.json] are not read again: the zone is opened over the store path
    the judgment read, and the mode is the mode of the log. It publishes
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
  | Login_client_refused of Server_account_login.refusal
      (** A login client that [config.json] names was refused: the
          environment variable of its secret is not set or holds the empty
          string, its redirect is no [https] URL, or the path of its
          redirect is not the callback of its provider. *)
  | Route_of_another_kind of Server_account_table.refusal
      (** The table holds a route that is neither [Always_public] nor
          [Self_authenticated] with [Browser_session] or [Person_mcp]. *)
  | Https_listener_refused of string
      (** {!Server_bootstrap_http.https_listener_of_env} refused. *)
  | Listener_not_bound of
      { host : string
      ; port : int
      ; reason : string
      }  (** The cleartext listener did not bind, for example a port in use. *)
  | Trust_policy_refused of Server_request_authority.trust_policy_error
  | Port_not_announced of Server_startup_takeover.base_path_lock_rejection
      (** The port that bound could not be announced to the host
          ({!Server_startup_takeover.announce_account_server}). No command
          could replace a server whose port the host cannot read. *)
  | Access_not_published of Runtime_account_access.publish_error
      (** This process published its access before. A boot publishes once,
          so no boot of [masc start] meets it. *)

val refusal_to_string : refusal -> string

val health_version : string -> string option
(** The release version in a body that [GET /health] of this server answered,
    for a command line that names the server it is about to replace. [None]
    for any other body. It identifies nothing: which workspace a port belongs
    to is read from the kernel
    ({!Server_startup_takeover.account_server_port_holder}). *)

(** Reads the HTTP mode, opens the zone and reads it again, builds the login
    clients, makes the table, binds [address]:[port], binds the HTTPS listener of the environment,
    makes the trust policy, announces the port to the host under [lease]
    ({!Server_startup_takeover.announce_account_server}), publishes the
    access, gives the environment and [sw] to the transport of a login
    ([Eio_context]), records the port for the CLI of the workspace
    ([Workspace_connection]), calls [on_ready], and serves until [sw] is
    cancelled. A refused boot has not set the two. The two are one value
    each for the process: a process runs one account server, and a second
    [run] in it would replace what the first one set. The cleartext listener follows the HTTP mode of the
    environment, as the single-user server does. [lease] is the BasePath
    lease of the base path that was judged.

    An [Error] comes before a connection is accepted and before the port is
    recorded, and the refusals come in the order of the constructors of
    {!refusal}. {!Trust_policy_refused}, {!Port_not_announced} and
    {!Access_not_published} come with the port bound: the trust policy names
    the HTTPS port that bound.

    The announcement comes after every check that can stop the boot of
    [masc start], so a command that reads it reads a server that goes on to
    serve ([masc restart] takes a replacement for ready on it). The one
    refusal after it, {!Access_not_published}, needs a process that
    published before.

    On disk a refused boot leaves two things. After the table check,
    {!Server_bootstrap_http.https_listener_of_env} makes a self-signed
    certificate under the base path ([.masc/tls]) when the HTTPS listener is
    on, no certificate file is configured, and the pair there is missing,
    unreadable or due for renewal. From {!Port_not_announced} on, the empty
    file the announcement lock is taken on may be there, beside the lease:
    the first announcement makes it, nothing removes it, and it holds no
    lock once the process ends. In the process a refused boot leaves the
    host, the port and the URLs that
    {!Server_bootstrap_http.make_http_config} writes to the environment, the
    metrics of the HTTPS listener, the sockets that bound until [sw] ends,
    and, at {!Access_not_published}, the announcement of the port, which
    ends with the lease or with the process. The caller ends the process on
    a refusal.

    The accept loop and the record of the port are the steps of the
    single-user boot ([run_serving] in [Server_runtime_bootstrap]), written a
    second time here. *)
val run
  :  sw:Eio.Switch.t
  -> env:Eio_unix.Stdenv.base
  -> address:Ipaddr.t
  -> port:int
  -> lease:Server_startup_takeover.base_path_lease
  -> ?on_ready:(unit -> unit)
  -> Authz_boot_mode_read.multi_account
  -> (unit, refusal) result
