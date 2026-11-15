(** What a route says about who may call it, as data.

    [Server_route] derives a value from the typed auth kind of a registration and
    stores it on the route, so the route table can be read without running a
    handler. *)

(** Why a route authenticates the request itself instead of using one of the
    other kinds. Each reason is a route family whose handler answers a missing
    credential on its own; the A1 baseline
    (docs/evidence/2026-10-28-auth-route-baseline/) measured how these families
    answer without one. *)
type self_authenticated_reason =
  | Mcp_transport
      (** [/mcp] and its profiles, and the observer streams [/ag-ui/events] and
          [/events/presence]: the transport answers 401 with a
          [WWW-Authenticate] challenge. *)
  | Oauth_protocol
      (** The OAuth endpoints, the discovery documents that go with them and the
          callback pages, which run before the caller has a credential. *)
  | Websocket_upgrade
      (** An upgrade route ([/ws], the IDE LSP proxy): the handler checks the
          credential before it upgrades. [/ws] checks it for an upgrade only: a
          [GET /ws] that does not ask to upgrade gets the discovery document
          without one. The IDE LSP proxy checks every request. *)
  | Browser_session
      (** The multi-account login routes and the routes a browser session calls
          ([/auth/...], [/api/v1/auth/allowlist], [/api/v1/auth/invites],
          [/api/v1/auth/members] and [/api/v1/auth/pats]): the
          start and the callback of a login run before the browser has a
          session, and the others check the session cookie, the origin and,
          for a request that changes something, the CSRF token in their own
          code ([Authz_browser_request.check]), answering 401 or 403. *)
  | Person_mcp
      (** The MCP endpoint of a person on the account server ([POST /mcp],
          plan S1b): the handler judges the credential of every request by
          [Auth_gate.decide], a browser session or a scoped PAT, for the
          method or the tool that the request names. It keeps no MCP session
          and takes no caller name from the request. *)
  | Loopback_dev_token
      (** [/api/v1/dashboard/dev-token]: the handler answers 404 unless the bind
          is loopback and strict auth is off. Past that it runs [with_public_read]
          itself (503 before the server is ready, 400 or 409 for a workspace
          precondition that fails) and hands out the dashboard token without a
          credential (#46560). *)
  | Subpath_dispatch
      (** A prefix route whose handler picks the authentication by the part of
          the path after the prefix ([/api/v1/keepers/]). The kinds of its
          sub-routes are not in the route table. *)

(** What a [Public_read] route asks for when strict auth is on. *)
type strict_reading =
  | Credential_when_strict  (** A read credential, as [Read_auth] asks for. *)
  | Open_when_strict  (** Nothing: the route stays open, as on the default configuration. *)

type t =
  | Always_public  (** Open on every configuration, strict auth included. *)
  | Public_read of strict_reading
      (** Open on the default configuration, with the server state, its
          readiness and the workspace precondition; under strict auth it asks
          for what [strict_reading] says. *)
  | Read_auth
  | Permission of Masc_domain.permission
  | Token_permission of Masc_domain.permission
  | Private_token_permission of Masc_domain.permission
  | Tool of { tool_name : string }
  | Tool_observation of { tool_name : string }
      (** Tool authorization with read quota for GET/HEAD observations. *)
  | Tool_actor of { tool_name : string }
  | Manage_own_provider
      (** A person manages their own provider accounts: they link a
          subscription and follow, answer, or end its login (design 5.4, plan
          D1-3). In multi-account mode every active person may, an Admin and
          a Member alike, and a PAT needs [Manage_own_provider] in its scope;
          a service may not. *)
  | Manage_own_keeper
      (** A person manages their own Keepers: they make one, give it one of
          their Runtimes (design 4.3, plan D1-5), and send it a message that
          it answers on that Runtime (plan D2-8). It is open as
          [Manage_own_provider] is, with [Manage_own_keeper] in the scope of a
          PAT. *)
  | Self_authenticated of self_authenticated_reason

(** JSON for the route inventory. [kind] is the constructor in snake case;
    permissions use {!Masc_domain.permission_to_string}. *)
val to_json : t -> Yojson.Safe.t
