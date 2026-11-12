(* HIGH-RISK-UNREVIEWED: reads the requests of the login routes and writes their
   answers. A callback answer carries the session cookie that lets a browser act
   as a principal. *)

(** The server side of the login routes (plan C3-8c): the transport of a login
    to its provider over {!Masc_http_client}, and the HTTP/1 handlers of
    {!Login_routes}, {!Login_allowlist_routes}, {!Login_invite_routes} and
    {!Login_pat_routes}.

    A handler reads the request into the values those modules take and writes
    their answer as it is: its status, its headers (each [set-cookie] among
    them) and its body. The account server calls {!add_routes} at boot with
    the zone it opened ({!Server_accounts}, plan S1a-3a). A handler reads and
    answers through {!Http_reqd}, so a request of either protocol passes the
    same code. *)

(** A [GET] and a [POST] to a provider, with the shared deadline
    ({!Masc_http_client.default_request_timeout_sec}) and the bound of
    {!Login_transport.max_answer_bytes}: a longer answer is an [Error], and
    its connection is closed. *)
val get : clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> Login_transport.get

val post : clock:[> float Eio.Time.clock_ty ] Eio.Resource.t -> Login_transport.post

(** 16 KiB. The form of a start and an identity to register are under a KiB.
    A longer body is a 413, and no route reads it. *)
val max_request_bytes : int

(** Registers, each as [Self_authenticated Browser_session]:
    - [POST /auth/oidc/start] and [GET /auth/oidc/callback] (Google)
    - [POST /auth/github/start] and [GET /auth/github/callback]
    - [POST /auth/logout] and [GET /auth/session]
    - [POST /api/v1/auth/allowlist] and [DELETE /api/v1/auth/allowlist/<id>]
    - [POST /api/v1/auth/invites] and [DELETE /api/v1/auth/invites/<id>]
    - [POST] and [GET /api/v1/auth/pats], and [DELETE /api/v1/auth/pats/<id>]

    A form or a query is read as pairs in order, so a field that comes twice
    reaches the route twice and is refused there. A value with a bare comma
    comes as two pairs, as {!Uri} splits it; a browser percent-encodes the
    comma of a form. A request other than a callback needs the authority that
    the server admitted at its entry, to classify its [Origin]; one without it
    is a 500. *)
val add_routes : Login_routes.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

(** [/auth/oidc/callback]: the redirect of a Google login client is this
    path on the address of the server. *)
val google_callback_path : string

(** [/auth/github/callback]: the redirect of a GitHub login client is this
    path on the address of the server. *)
val github_callback_path : string

(** The pages and the routes of a person (plan, preview scope P3, and
    S1a-3b), on top of {!add_routes}:
    - [GET /] and [GET /accounts/invite], the pages of {!Auth_preview}, open
      ([Always_public]); each page gets a fresh nonce from [draw]
    - [GET /api/v1/auth/whoami], judged by {!Auth_gate.decide} on one
      snapshot of the zone. It reads every [Authorization] and
      [x-masc-internal-token] field and every session cookie, so two of them
      are several credentials.

    - [GET /api/v1/auth/provider-accounts], the subscriptions of the person
      ({!Auth_preview.provider_accounts})
    - [GET /api/v1/auth/integrations], what the person may connect and
      whether its models are called here ({!Server_person_integrations},
      plan L2a)
    - [POST /api/v1/setup/accounts/login] and [GET] and [POST] under
      [/api/v1/setup/accounts/login/], the subscription connect route of the
      server ({!Server_setup_account_login}) for the person, with the account
      home under the workspace [base_path] (plan D1-4)
    - [POST /api/v1/setup/accounts/verify], one call of the person's own
      account ({!Server_setup_account_login.verify}, plan D1-6a)
    - [GET] and [POST /api/v1/auth/keepers] and
      [POST /api/v1/auth/keepers/assign], the Keepers of the person
      ({!Auth_preview_keeper}, plan D1-5)
    - [POST /api/v1/auth/keepers/turn], one turn of the person's Keeper on
      the Runtime they gave it ({!Server_preview_keeper_turn}, plan D2-8)
    - [POST /api/v1/auth/keepers/conversation], a new conversation of the
      person's Keeper ({!Server_preview_keeper_turn.start_conversation},
      plan S1b-3)
    - [POST /mcp], the MCP endpoint of the person ({!Server_person_mcp},
      plan S1b-1), registered as [Self_authenticated Person_mcp]. It is
      judged as [Read_auth] before its body is read, and each tool makes
      the judgment of the route it stands for

    Each of these routes is judged on one snapshot that the zone could be
    trusted for ({!Authz_zone.read}). A zone whose file stopped, or whose
    files disagree, gives none, and the request gets the 503 of
    {!Login_routes.zone_uncertain} before a credential is read.

    The subscription routes and the integrations are judged as
    [Manage_own_provider] by {!Auth_preview.person} on that snapshot, and a
    request that does not pass gets its 401 or 403 before its handler reads
    anything.
    The Keeper routes are judged the same way as [Manage_own_keeper] by
    {!Auth_preview.keeper_owner}, and the turn by
    {!Auth_preview.keeper_turn_caller}, which gives the namespace of the
    person and the token that authenticated the request as well: the turn
    runs only inside the scope of that token.

    The account server ({!Server_accounts}) and the preview command
    register them. [env] is the environment of the process, from which a
    turn starts the client. *)
val add_person_routes
  :  Login_routes.t
  -> env:Eio_unix.Stdenv.base
  -> base_path:string
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t

