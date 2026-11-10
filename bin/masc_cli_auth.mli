(* HIGH-RISK-UNREVIEWED: this command writes the first records of a
   multi-account installation and prints the one link that lets the first
   Admin in. *)

(** [masc auth bootstrap], [masc auth invite], [masc auth off] and
    [masc auth preview]. *)

(** [masc auth bootstrap]: activates a multi-account installation on a base
    path where no server runs (design 5.1-1, 8.4, plan B3d-1).

    The command takes the BasePath lease, so a running server, another
    activation, or a server that starts meanwhile waits on the lease or is
    refused. Before anything is written it reads [MASC_HTTP_BASE_URL], the
    public address that the person opens, and refuses when it is not an http(s)
    origin with no path; [MASC_HOST] and [MASC_HTTP_PORT] are not read, because
    the server can listen elsewhere. It then runs {!Authz_activation.activate}
    with the anonymous-mutation setting of this process's environment, which a
    server started from the same environment reads, and prints
    {!Authz_activation.link} once on standard output. The link is printed
    nowhere else.

    Returns the exit code: [0] once the link is printed, [1] otherwise, with
    the reason on standard error. *)
val bootstrap : base_path:string -> external_store:string -> int

(** [masc auth invite]: writes one more Admin invitation with
    {!Authz_activation.invite}, under the lease and with the reads of
    {!bootstrap} first, and prints its link once. For a first invitation that
    expired before it was spent, or whose link was lost. Same exit codes. *)
val invite : base_path:string -> int

(** [masc auth off]: turns the accounts of an activated workspace off with
    {!Authz_off.turn_off}, under the lease of {!bootstrap}, and prints the
    workspace (design 10.5, plan F3a-2). It reads neither [MASC_HTTP_BASE_URL]
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
    it runs, so no server runs on the base path meanwhile. It serves the login
    routes and the routes of {!Server_login_http.add_preview_routes}, and none
    of the Keeper, Runtime, MCP or Board routes of the server. The GitHub
    client is
    {!Login_client.loopback} with [github_client_id] and the secret of
    {!github_client_secret_env}, whose value is printed nowhere.

    Returns [1] with the reason on standard error when it cannot start, and
    [0] when the listener stops. *)
val preview : base_path:string -> port:int -> github_client_id:string -> int

