(* HIGH-RISK-UNREVIEWED: this module decides whether a request in multi-account
   mode reaches a route, and as whom. A request it allows acts as the principal
   it names, with the permissions of its role. *)

(** The gate of a multi-account request (design 5.3, plan C4-8).

    [decide] reads the credential the request presents
    ({!Authz_credential_presentation}), authenticates it against one snapshot
    of the authorization state that the zone could be trusted for
    ({!Authz_zone.read}), and judges it against the kind of the route
    ({!Route_access.t}). A zone whose files stopped or disagree gives no such
    snapshot, so its caller answers before the gate. It answers [Ok] or [Error]; there is no third answer
    that logs and lets through (design 5.3). Single-user requests do not come
    here: their own functions judge them (user decision 2026-11-07).

    {b Roles} (user decision 2026-11-08). A Human with an Admin assignment in
    force has the permissions of [Admin]; another active Human and a service
    have those of [Worker]. No [agent_credential] role is read.

    {b PATs} (design 4.4, user decision 2026-11-08). A request that comes with
    a PAT never gets [CanInit], [CanReset] or [CanAdmin]. Its other
    permissions need an effect in the scope of the PAT: [CanReadState] needs
    [Read_state], and the task permissions need [Use_tool].

    {b Own provider accounts} (plan D1-3). A [Manage_own_provider] route is
    open to every active Human, an Admin and a Member alike, as the account
    they link is theirs. A PAT needs [Manage_own_provider] in its scope, and a
    service is refused. A [Manage_own_keeper] route is open the same way, as
    the Keeper a person makes is theirs (plan D1-5), with
    [Manage_own_keeper] in the scope of a PAT.

    {b Kinds.} [Always_public] and [Public_read Open_when_strict] need no
    credential: multi-account mode is strict, and the A4d routes stay open
    under strict auth. Every other kind needs one,
    except the routes of a browser login, which judge the request themselves
    ([Self_authenticated Browser_session]): the start and the callback of a
    login run before the browser has a session. The MCP endpoint of a person
    ([Self_authenticated Person_mcp]) judges itself as well: it calls {!decide}
    for the method or the tool that each message names. The OAuth routes and the
    loopback dev token are not served in multi-account mode. A credential that
    is presented is authenticated on every kind, so a revoked or legacy one is
    refused even where none is needed. *)

(** What authenticated the request. *)
type binding =
  | Session of Authz_types.Session_id.t
  | Pat of Authz_types.Pat_id.t
  | Service_credential of Authz_types.Service_credential_id.t

type authenticated =
  { principal : Authz_types.Principal.t
  ; binding : binding
  ; pat_binding : Authz_types.Pat_binding.t
        (** [Not_pat] but for a PAT: {!Authz_decision} reads it (design 5.3). *)
  ; role : Masc_domain.agent_role  (** [Admin] or [Worker]. *)
  }

type allowed =
  | Anonymous  (** The route needs no credential, and the request presents none. *)
  | Authenticated of authenticated
  | Judged_by_route
      (** A route of a browser login, which checks the cookie, the origin and
          the CSRF token itself ({!Authz_browser_request.check}). *)

type reason =
  | Credential_required
  | Several_credentials
  | Query_credential
  | Unreadable of Authz_credential_presentation.unreadable
  | Legacy_credential_forbidden
  | Mcp_oauth_token_not_bound  (** Until the layer that binds it to a session (plan C5). *)
  | Session_refused of Authz_browser_request.refusal
  | Pat_refused of Authz_pat.refusal
  | Service_credential_refused of Authz_service_credential.refusal
  | Permission_denied of Masc_domain.permission  (** The role does not hold it. *)
  | Pat_admin_permission of Masc_domain.permission
  | Pat_scope_lacks of
      { permission : Masc_domain.permission
      ; effect_ : Authz_types.Effect.t
      }
  | Unregistered_tool of string
  | Not_served_in_multi_account of Route_access.self_authenticated_reason
      (** The OAuth routes until plan C5, and the loopback dev token. *)
  | Service_owns_no_provider of Authz_types.Service_id.t
      (** A [Manage_own_provider] route, and a service calls it: a person
          links their own subscription (plan D1-3). *)
  | Pat_scope_lacks_own_provider
      (** A [Manage_own_provider] route, and the scope of the PAT does not
          hold that effect (design 4.4). *)
  | Service_owns_no_keeper of Authz_types.Service_id.t
      (** A [Manage_own_keeper] route, and a service calls it: a person makes
          their own Keeper (plan D1-5). *)
  | Pat_scope_lacks_own_keeper
      (** A [Manage_own_keeper] route, and the scope of the PAT does not hold
          that effect (design 4.4). *)

(** [true] for the reasons that a request without a working credential gets
    (401); [false] for those of an authenticated request that may not do this
    (403). *)
val is_unauthenticated : reason -> bool

val reason_to_string : reason -> string

(** What the server took from the request. [method_], [origin] and [csrf] are
    read for a browser session (design 5.3). *)
type request =
  { credentials : Authz_credential_presentation.request
  ; method_ : Authz_browser_request.method_
  ; origin : Authz_browser_request.origin
  ; csrf : string option
  }

val decide
  :  Authz_zone.trusted
  -> now_ms:int
  -> Route_access.t
  -> request
  -> (allowed, reason) result
