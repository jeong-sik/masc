(** Attaching one Keeper to one work service, from a keypress to credentials
    the Keeper's next turn can read.

    Two requests with a browser between them. The first says which Keeper and
    which provider and hands back a URL; the operator consents there; the
    provider sends the browser to the second, which redeems the code and
    writes what came back into that Keeper's secret projection.

    This is where the layering turns over. {!Keeper_oauth_session} knows an
    exchange and refuses to know that Keepers have secret directories; this
    module knows both, because it is the part of masc that owns the
    workspace. *)

val callback_path : string
(** The path every provider sends the browser back to. One path for all of
    them: which login a callback belongs to is the state it echoes, and a
    state is unguessable and redeemable once. *)

val callback_json : unit -> Yojson.Safe.t
(** The callback a login started now would name for a provider without a
    callback of its own: [{url}], or [{problem}] when this server does not
    know its own base URL. It follows [MASC_HTTP_BASE_URL], or the address the
    server bound when that is unset, so it changes when the server moves. A
    provider declared [callback = "loopback"] carries its own in each row. *)

val declarations_json : base_path:string -> Yojson.Safe.t
(** Every provider declared under [config/identity/], as a screen could list
    them. A provider declared [callback = "loopback"] also carries
    [callback: {kind: "loopback", url | problem}]. A readable declaration
    carries a tagged [app_state] object whose
    [kind] says whether an operator app is on file: ["on_file"], ["none"], or
    ["problem"]. The last also carries the store's [problem]. A declaration
    nobody can read is
    itself [{id, problem}],
    because the alternative is a shorter list with no reason the provider is
    missing. No client id or secret is returned. *)

val set_client :
  base_path:string ->
  provider_id:string ->
  client_id:string ->
  client_secret:string option ->
  scopes:string ->
      (** Space-separated, and empty to ask for whatever the resource
          publishes. An app an operator brought is the authority on what it
          may be granted: asking for a scope it does not declare is refused,
          and adding that scope means reinstalling an app other people may
          depend on. *)
  (Yojson.Safe.t, string) result
(** Record an app an operator made themselves.

    For a provider whose authorization server offers no registration
    endpoint there is no other way in: Slack, GitHub and Figma all publish
    one client per app and expect the operator to have made it. {!start}
    uses an app on file instead of registering, so this is the road in.

    One per client group for this install rather than one per Keeper: the app
    belongs to the install, and every Keeper's login uses it.

    The answer says whether a secret is on file and never what it is. It does
    say the scopes, which are not a credential and are the thing an operator
    most needs to check. *)

val start :
  ?transports:Keeper_identity_tools.transports ->
      (** How the provider is reached; production passes nothing and gets
          {!Keeper_identity_tools.http_transports}. *)
  ?register:
    (registration_url:string ->
     client_name:string ->
     redirect_uri:string ->
     (Keeper_oauth_registration.registered, Keeper_oauth_registration.error) result) ->
      (** How a client is registered; production passes nothing and gets the
          clock-bound RFC 7591 request. *)
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  keeper:string ->
  provider_id:string ->
  now:float ->
  unit ->
  (Yojson.Safe.t, string) result
(** Begin a login. Finds the declaration, asks the provider's server where
    its authorization lives, uses the operator's app or registers a fresh client
    for this login's callback, and returns the URL to open along with a
    non-secret [attempt_id] for authenticated completion observation. Callback
    state is kept inside the browser URL only.

    Nothing is written here yet -- an operator who closes the browser leaves no
    trace on this side. A client registered for that login stays registered at
    the provider: this install keeps no registration management credentials
    (RFC 7592), so it cannot delete one. *)

val write_finished_credential :
  base_path:string ->
  provider:Keeper_oauth_provider.t ->
  finished:Keeper_oauth_session.finished ->
  Keeper_oauth_pending.credential_write ->
  (unit, string) result
(** One stage of storing a finished login, as the callback runs it inside
    {!Keeper_oauth_pending.publish_credentials}. The refresh-token stage also
    removes the record of the client an earlier login used, so an interrupted
    publication never leaves a new token beside an old client. The client
    stage records the client that redeemed this login's code. *)

type attached = {
  keeper : string;
  provider_id : string;
  provider_label : string;
  expires_at : float option;
      (** When the provider said this credential lapses. Absent when it
          named no moment, which is a shape some providers issue rather than
          one this refuses -- see {!Keeper_oauth_session.expiry}. *)
  warning : string option;
      (** What the operator has to know before they walk away from the page,
          or [None] when the login left nothing hanging. Carried beside the
          success rather than raised as one: the credentials are on disk
          either way, and the thing worth saying is about what happens
          later. *)
  tool_discovery : (int, string) result;
      (** How many tools the provider named, or why asking did not work.

          Asked right here, because an operator who just consented wants to
          know whether it took, and a first tool call is a slow way to find
          out. A failure does not undo the attachment: the credentials are
          written either way, and {!refresh_tools} can be asked again. *)
}

val refresh_tools :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  keeper:string ->
  provider_id:string ->
  now:float ->
  (Yojson.Safe.t, string) result
(** Ask an attached provider what tools it has, and write the answer down.

    Done when a Keeper attaches, and whenever an operator asks. Not on a
    timer: a stale catalog is visible and fixable, while a timer is a
    network call nobody asked for. *)

val attached_tools_json : base_path:string -> keeper:string -> Yojson.Safe.t
(** What every declared provider currently offers this Keeper, as a screen
    would list it: when it was found out, and the tool names. A provider this
    Keeper never attached to is listed as such rather than left out, because
    "not attached" and "attached with no tools" are different things to
    whoever is looking. Each readable row also carries [app_state], the same
    object {!declarations_json} gives, and a provider declared
    [callback = "loopback"] carries its own
    [callback: {kind: "loopback", url | problem}]. *)

val redirect_uri_for : Keeper_oauth_provider.t -> (string, string) result
(** The redirect URI a login for this provider names: this server's callback
    under its base URL, or for a provider declared [callback = "loopback"]
    the RFC 8252 loopback form: [http://127.0.0.1:<bound port>/...] when the
    server bound 127.0.0.1 or a wildcard, [http://[::1]:<bound port>/...]
    when it bound ::1, and an [Error] for any other bind, 127.0.0.2
    included. *)

val finish :
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  state:string ->
  code:string ->
  now:float ->
  (attached, string) result
(** Redeem the code the browser carried and write the result into the
    Keeper's own secret scope: the access token and its expiry as env
    entries, the refresh token as a file entry, each at the name the
    declaration gives.

    Returns what an operator needs to read on the page they land on. Not the
    tokens: the browser that arrives here belongs to whoever followed the
    redirect, and the point of the exchange is that the credential goes to
    the Keeper rather than through a screen. *)

val attempt_status_json : base_path:string -> now:float -> keeper:string -> provider_id:string -> attempt_id:string -> Yojson.Safe.t
(** Authenticated exact-scope read of non-secret login completion facts. *)

val reject_callback : base_path:string -> state:string -> now:float -> unit
(** Only a still-awaiting consent is rejected. Replay cannot fail an admitted callback. *)

type revocation =
  | Revoke_not_published
      (** the provider publishes no revocation endpoint, or there was no token
          of ours to revoke (a GitHub CLI provider's credential belongs to
          [gh], which masc never wrote) *)
  | Revoke_not_sent of string
      (** there is a token and an endpoint, but the client the token was
          issued to could not be named -- no record of the login's client, or
          one that cannot be read or used -- so no request was sent; the
          string says which *)
  | Revoke_revoked  (** the endpoint answered a success *)
  | Revoke_failed of string  (** the endpoint answered a refusal, or nothing *)

val disconnect :
  ?transports:Keeper_identity_tools.transports ->
      (** How the provider is reached. Production passes nothing and gets
          {!Keeper_identity_tools.http_transports}; a test injects its own so
          the best-effort revoke is exercised without the network. *)
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace.config ->
  keeper:string ->
  provider_id:string ->
  now:float ->
  unit ->
  (Yojson.Safe.t, string) result
(** Detach one Keeper from one declared provider.

    Deletes the refresh token file entry, clears the access-token and expiry
    env entries, and deletes the tool catalog that made the attachment
    visible to the Keeper's runtime -- so the next turn stops offering its
    tools. Then, best effort, asks the provider to forget the refresh token
    (RFC 7009) when it publishes a revocation endpoint, and reports that
    outcome separately: a local deletion and a provider revocation are not
    the same act, and a provider that cannot be reached does not undo the
    deletion. The returned object is also written as a receipt under
    [.masc/identity/disconnects/<keeper>/<provider>.json]. *)
