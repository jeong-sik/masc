(* HIGH-RISK-UNREVIEWED: bridges operational dashboard read/admin routes and
   the cookie-authenticated observer SSE stream onto the multi-account server.
   Every route registered here is [Self_authenticated Multi_account_dashboard]
   and judges the request itself via {!Auth_gate.decide} against one trusted
   snapshot of the authorization zone; no single-user [Server_auth] wrapper is
   used. *)

(** Multi-account operational dashboard and cookie-authenticated observer SSE
    bridge ({!Server_accounts}).

    All routes registered by {!add_routes} carry
    [Server_route.Self_authenticated Route_access.Multi_account_dashboard] and
    authorize every request through {!authorize} before reading request bodies
    or touching the engine state:
    - {!Workspace_read}: judged as {!Route_access.Read_auth} via
      {!Auth_gate.decide}. Permits active [Admin] and [Worker] principals
      (browser sessions, PATs with [Read_state], and service credentials).
      Board reads always use {!Masc_board_handlers.Board_access.Workspace_member}
      derived from the authorized principal and its owned Keepers so an Admin
      never reads another principal's [Direct] posts.
    - {!Admin_only}: judged as [Route_access.Permission Masc_domain.CanAdmin]
      via {!Auth_gate.decide}. Permits only active [Admin] browser sessions
      (with Same-Origin and CSRF enforcement on unsafe methods); [Worker]
      principals, PATs, and service credentials are refused with 403.
    - {!Browser_observer_sse}: judged as {!Route_access.Read_auth} via
      {!Auth_gate.decide} AND restricted to browser session bindings
      ({!Auth_gate.Session}) with no query-string credentials
      ({!Auth_gate.Query_credential} yields 401) and no cross-origin requests.
      Session validity is re-checked against {!Authz_zone.read} on every
      published frame and keepalive tick so signed-out, disabled, or deleted
      principals are disconnected promptly. *)

(** [/api/v1/auth/events]: cookie-authenticated observer SSE endpoint for the
    unified web dashboard in multi-account mode. *)
val observer_events_path : string

type access_tier =
  | Workspace_read
  | Admin_only
  | Browser_observer_sse

type authorized =
  { caller : Auth_gate.authenticated
  ; state : Authz_state.t
  }

(** Pure authorization judgment for a multi-account dashboard bridge route on
    one trusted snapshot of the authorization zone. Returns [Ok authorized]
    when the caller satisfies [access_tier], or [Error answer] with a
    [cache-control: no-store] JSON error response (401 or 403). *)
val authorize
  :  Authz_zone.trusted
  -> now_ms:int
  -> access_tier
  -> Auth_gate.request
  -> (authorized, Login_routes.answer) result

(** Derives the privacy-preserving {!Masc_board_handlers.Board_access.reader}
    for an authorized multi-account caller: always [Workspace_member] scoped
    to the caller's principal id and the engine names of the Keepers it owns
    in [state], never [Operator]. *)
val board_reader_of
  :  state:Authz_state.t
  -> Auth_gate.authenticated
  -> Masc_board_handlers.Board_access.reader

(** Registers the RBAC-gated operational dashboard routes and the
    cookie-authenticated observer SSE stream ({!observer_events_path}) on the
    account server router. Every route checks {!authorize} before inspecting
    [engine_state]; an authorized request while [engine_state ()] is [None]
    answers 503 [{"error":"engine_starting"}]. *)
val add_routes
  :  sw:Eio.Switch.t
  -> clock:float Eio.Time.clock_ty Eio.Resource.t
  -> login:Login_routes.t
  -> base_path:string
  -> engine_state:(unit -> Mcp_server.server_state option)
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t
