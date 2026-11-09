(** Open pull requests of the registered GitHub repositories (RFC-0465 §2-§4).

    The server reads every repository registered in
    [.masc/config/repositories.toml] whose remote is on the configured GitHub
    host, one GraphQL query per repository page, with the token of the Keeper
    named by runtime.toml [\[repositories\] pr_reader]. Nothing here is
    persisted: GitHub is the source of these facts, so a restart starts at
    [Repository_pulls.Pulls_not_read] and the next read replaces it. The data
    types, the JSON projection and the published snapshot are in
    {!Repository_pulls}.

    The host and the GraphQL endpoint are operator configuration, not code:
    [\[repositories\]] accepts optional [github_host] (a bare hostname, read
    in lower case, default {!default_github_host}) and [graphql_url] (an [https://] URL,
    default {!default_graphql_url}). A GitHub Enterprise host sets both; the
    token is then read from the reader Keeper's [github-cli/hosts.yml]
    section for that host. A non-default [github_host] without [graphql_url]
    is invalid: its slugs posted to the default endpoint could only answer
    NOT_FOUND.

    The reader is resolved again on every refresh. runtime.toml, the Keeper
    declaration and the Keeper's [github-cli/hosts.yml] token are all read at
    that moment and nothing is kept between refreshes, so a Keeper that logs
    in again or out is followed by the next read. When the reader cannot be
    used, no repository is read with any other credential. *)

(** {1 Transport} *)

type response =
  { status : int
  ; body : string
  ; rate_limit_remaining : int option
  ; rate_limit_reset : float option
      (** GitHub's [x-ratelimit-remaining] and [x-ratelimit-reset] headers. *)
  ; retry_after_s : int option
      (** GitHub's [retry-after] header in seconds. A 403 or 429 carrying it
          is a rate limit even while [x-ratelimit-remaining] is above 0
          (GitHub's secondary rate limit), and its wait is taken before
          [x-ratelimit-reset]. *)
  }

type http_post =
  url:string -> token:string -> body:Yojson.Safe.t -> (response, string) result
(** Injected transport. Production passes {!default_http_post}; tests pass a
    stub that answers from recorded bodies. *)

val default_http_post : http_post
(** curl through {!Process_eio}. The token goes to curl on stdin
    ([-H \@-]), never on the command line where other local users could read
    it from the process table. *)

type http_get = url:string -> token:string -> (response, string) result
(** Injected transport for one GET. Production passes {!default_http_get}. *)

val default_http_get : http_get
(** curl through {!Process_eio}, the token on stdin as {!default_http_post}
    sends it. *)

(** {1 Reading} *)

val default_github_host : string
(** [github.com]: the remote host read when [\[repositories\]] declares no
    [github_host]. *)

val default_graphql_url : string
(** [https://api.github.com/graphql]: the endpoint posted to when
    [\[repositories\]] declares no [graphql_url]. *)

val github_slug_of_remote : ?host:string -> string -> string option
(** [owner/repo] for the three spellings git accepts for a [host] remote
    ([https://<host>/o/r(.git)], [git\@<host>:o/r(.git)],
    [ssh://git\@<host>/o/r(.git)]); [None] for anything else.
    [host] defaults to {!default_github_host}. The host is compared without
    case (DNS names are case-insensitive, RFC 4343); [owner/repo] keeps the
    remote's case. *)

val read_repository :
  now:(unit -> float) -> http_post:http_post -> token:string -> ?graphql_url:string -> string -> Repository_pulls.repository_pulls
(** [read_repository ~now ~http_post ~token ~graphql_url slug] reads every
    open pull request of [slug], following the GraphQL cursor until GitHub
    reports no next page. Every page is posted to [graphql_url], default
    {!default_graphql_url}. *)

val refresh :
  now:(unit -> float) -> http_post:http_post -> config:Workspace.config -> previous:Repository_pulls.snapshot -> Repository_pulls.snapshot
(** One full read: resolve the reader, load the registered repositories and
    read each GitHub one. The persisted Keeper names are listed once, first. A repository whose previous answer was
    [Token_rejected] for the same token at the same [graphql_url], or [Rate_limited] with a reset time
    still ahead of [now], keeps that answer and is not fetched. When the
    reader is not ready, nothing is fetched and
    every GitHub repository reads [Pulls_not_read]: an earlier read is not
    shown as current. [previous] only stands in when the repository list
    itself cannot be read. *)

val refresh_raised : previous:Repository_pulls.snapshot -> exn -> Repository_pulls.snapshot
(** What {!start} publishes when {!refresh} raises: [previous] with
    [repositories_error] saying so. *)

val start : sw:Eio.Switch.t -> clock:_ Eio.Time.clock -> config:Workspace.config -> unit
(** Forks the refresh loop under [sw]: one {!refresh} immediately, then one
    every 60 seconds. A refresh that raises publishes {!refresh_raised}.
    Cancelled with [sw]. *)

(** {1 Lane Add-on GitHub reads} *)

val lane_addon_github :
  now:(unit -> float) -> http_post:http_post -> config:Workspace.config -> Lane_addon_records.github
(** GitHub access for a Lane Add-on's [github_pulls] grant. Each call
    resolves the reader again, as {!refresh} does, finds the registered
    repository and its [owner/repo] on the configured host, and returns a
    [post] that sends one GraphQL request to the configured endpoint with the
    reader Keeper's token. The token never leaves this module. A reader that
    is not ready, an unregistered repository or a remote on another host is
    [Error]; so is an answer that {!refresh} would read as a failure. *)

(** {1 REST reads} *)

type rest_failure =
  | Reader_not_ready of Repository_pulls.reader
      (** The declared reader cannot be used and the state says why. It is
          never [Reader_ready]. *)
  | Reader_host_not_github of string
      (** The declared reader reads this host, not {!default_github_host}.
          The REST endpoint of another host is not derived from its GraphQL
          one. *)
  | Rest_transport_failed of string

val rest_get :
  http_get:http_get -> config:Workspace.config -> path:string -> (response, rest_failure) result
(** One GET of [path] on [https://api.github.com], the REST endpoint of
    {!default_github_host}, with the token of the reader declared in
    runtime.toml [\[repositories\] pr_reader]. The reader is resolved again on
    every call, as {!refresh} does, and the token never leaves this module.
    [path] starts with ['/'] and the caller built it from parts that cannot
    change its shape. Any HTTP status is [Ok]: what a status means is the
    caller's to read, for instance with {!failure_of_status}. *)

val failure_of_status : now_s:float -> response -> Repository_pulls.failure option
(** The failure an HTTP status stands for. [None] for a 2xx status. *)
