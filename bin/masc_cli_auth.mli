(* HIGH-RISK-UNREVIEWED: this command writes the first records of a
   multi-account installation and prints the one link that lets the first
   Admin in. *)

(** [masc auth bootstrap], [masc auth invite], [masc auth off] and
    [masc auth preview]. *)

(** [masc auth bootstrap]: activates a multi-account installation on a base
    path where no server runs (design 5.1-1, 8.4, plan B3d-1).

    The command takes the BasePath lease, so a running server, another
    activation, or a server that starts meanwhile waits on the lease or is
    refused. Before anything is written it reads the public address that the
    person opens, as a server started on the base path from this shell reads
    it: [MASC_HTTP_BASE_URL], or else [transport.http_base_url] of the
    runtime.toml of the base path, which it loads as the server does (settings
    that do not load refuse the command). It refuses when the address is not an
    http(s) origin with no path; [MASC_HOST] and [MASC_HTTP_PORT] are not read,
    because the server can listen elsewhere. It then runs the two steps of
    {!Authz_activation}
    with the anonymous-mutation setting of this process's environment, which a
    server started from the same environment reads, and prints
    {!Authz_activation.link} once on standard output. The link is printed
    nowhere else.

    Under the lease, between the checks of the activation
    ({!Authz_activation.prepare}) and its writes ({!Authz_activation.complete}),
    it puts the runtime.toml this build embeds at
    {!Server_runtime_setup_actions.config_path} where no entry is
    ({!Server_runtime_config_root_bootstrap.place_embedded_runtime_toml}): the
    account server reads what people may connect from that file. An entry
    that is there is kept. A command that a check refuses has made no file
    and no directory there. A placement that fails refuses the command with
    nothing activated, so the same command runs again.

    Returns the exit code: [0] once the link is printed, [1] otherwise, with
    the reason on standard error. *)
val bootstrap : base_path:string -> external_store:string -> int

(** [masc auth invite]: writes one more Admin invitation with
    {!Authz_activation.invite}, under the lease and with the reads of
    {!bootstrap} first, and prints its link once. For a first invitation that
    expired before it was spent, or whose link was lost. Same exit codes. *)
val invite : base_path:string -> int

(** [masc auth service-credential issue] (plan C4-9): issues a Service
    credential for [service] while no server runs on the workspace, and prints
    its token once. *)
val service_credential_issue : base_path:string -> service:string -> int

(** [masc auth service-credential revoke]: ends the credential [credential]. *)
val service_credential_revoke : base_path:string -> credential:string -> int

(** [masc auth service-credential list]: every credential with its service,
    the time it was issued and whether it is open. No secret is printed. *)
val service_credential_list : base_path:string -> int

(** [masc auth off]: turns the accounts of an activated workspace off with
    {!Authz_off.turn_off}, under the lease of {!bootstrap}, and prints the
    workspace (design 10.5, plan F3a-2). It reads neither the base URL
    nor the anonymous-mutation setting: the Off depends on the log and the
    external store alone. Returns [0] once the Off is committed, [1] otherwise,
    with the reason on standard error. *)
val off : base_path:string -> int

(** What a server does with an activated workspace, as a clause that follows
    "From now on" or "Once the command succeeds,": the success of {!bootstrap}
    and its help say the same sentence. *)
val account_server_line : string

(** The environment variable that holds the client secret of the GitHub OAuth
    App of {!preview}: [MASC_GITHUB_CLIENT_SECRET]. *)
val github_client_secret_env : string

(** 8940, a port the server does not take: [masc serve] listens on 8935. *)
val default_preview_port : int

(** [masc auth preview]: serves the localhost preview of multi-account login
    on [http://127.0.0.1:<port>] until the process ends (plan, preview scope
    P3).

    It goes on only where {!invite} would: a boot finds [Multi_account] with
    an external store that matches the log. It holds the BasePath lease while
    it runs, so no server runs on the base path meanwhile. It serves the
    routes of {!Server_accounts.add_routes_of_people}, as the account server
    does: the login routes, the routes of a person, the MCP endpoint of a
    person among them, and the console. It serves no Board route. Once it
    holds the lease it calls [select_dashboard], which picks the dashboard
    bundle the console is read from as [masc start] does. The GitHub client
    is {!Login_client.loopback} with [github_client_id] and the secret of
    {!github_client_secret_env}, whose value is printed nowhere.

    Returns [1] with the reason on standard error when it cannot start, and
    [0] when the listener stops. *)
val preview
  :  select_dashboard:(unit -> unit)
  -> base_path:string
  -> port:int
  -> github_client_id:string
  -> int

