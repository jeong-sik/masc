(* HIGH-RISK-UNREVIEWED: reads the requests of the login routes and writes their
   answers. A callback answer carries the session cookie that lets a browser act
   as a principal. *)

(** The server side of the login routes (plan C3-8c): the transport of a login
    to its provider over {!Masc_http_client}, and the HTTP/1 handlers of
    {!Login_routes} and {!Login_allowlist_routes}.

    A handler reads the request into the values those modules take and writes
    their answer as it is: its status, its headers (each [set-cookie] among
    them) and its body. S1 calls {!add_routes} at boot with the zone it opened,
    and writes the HTTP/2 arms; until then no server holds a zone. *)

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

    A form or a query is read as pairs in order, so a field that comes twice
    reaches the route twice and is refused there. A value with a bare comma
    comes as two pairs, as {!Uri} splits it; a browser percent-encodes the
    comma of a form. A request other than a callback needs the authority that
    the server admitted at its entry, to classify its [Origin]; one without it
    is a 500. *)
val add_routes : Login_routes.t -> Http_server_eio.Router.t -> Http_server_eio.Router.t

(** [/auth/github/callback]: the redirect of a GitHub login client is this
    path on the address of the server. *)
val github_callback_path : string

(** The routes of the localhost preview (plan, preview scope P3), on top of
    {!add_routes}:
    - [GET /] and [GET /accounts/invite], the pages of {!Auth_preview}, open
      ([Always_public]); each page gets a fresh nonce from [draw]
    - [GET /api/v1/auth/whoami], judged by {!Auth_gate.decide} on one
      snapshot of the zone. It reads every [Authorization] and
      [x-masc-internal-token] field and every session cookie, so two of them
      are several credentials.

    - [GET /api/v1/auth/provider-accounts], the subscriptions of the person
      ({!Auth_preview.provider_accounts})
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

    The subscription routes are judged as [Manage_own_provider] by
    {!Auth_preview.person} on one snapshot of the zone, and a request that does
    not pass gets its 401 or 403 before the connect handler reads anything.
    The Keeper routes are judged the same way as [Manage_own_keeper] by
    {!Auth_preview.keeper_owner}, and the turn by
    {!Auth_preview.keeper_owner_person}, which gives the namespace of the
    person as well.

    Only the preview command registers them; {!add_routes} is what a server
    registers (S1). [env] is the environment of the preview process, from
    which a turn starts the client. *)
val add_preview_routes
  :  Login_routes.t
  -> env:Eio_unix.Stdenv.base
  -> base_path:string
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t

