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
      never reads another principal's [Direct] posts. Keeper-scoped memory
      diffs enforce strict Keeper ownership ({!can_read_keeper_memory}), and
      Keeper-scoped sandbox reads require Admin or Keeper ownership
      ({!can_read_keeper_sandbox}).
    - {!Admin_only}: judged as [Route_access.Permission Masc_domain.CanAdmin]
      via {!Auth_gate.decide}. Permits only active [Admin] browser sessions
      (with Same-Origin and CSRF enforcement on unsafe methods); [Worker]
      principals, PATs, and service credentials are refused with 403. Covers
      config schema/patch, wiki writes, fleet sandbox inventory
      ([GET /api/v1/infra/sandboxes]) and sandbox probes, standalone/exact lane
      runs, ring logs, operator snapshot/digest/action/confirm, and schedule
      pruning.
    - {!Browser_observer_sse}: judged as {!Route_access.Read_auth} via
      {!Auth_gate.decide} AND restricted to browser session bindings
      ({!Auth_gate.Session}) with no query-string credentials
      ({!Auth_gate.Query_credential} yields 401) and no cross-origin requests.
      Requires a live engine state (returns 503 [{"error":"engine_starting"}]
      while [engine_state ()] is [None]) so every subscription binds the
      admitted workspace's [observer_instance_id] and never opens a stream that
      silently misses [Scoped_runtime_observers] events. Every replayed and
      live frame passes through {!project_observer_event} against a fresh
      trusted {!Authz_zone.read} snapshot so private Keeper chat/turn streams
      never leak to non-owners, raw [notifications/board] payloads (which carry
      [Direct] titles, 200-byte content previews, and post/comment ids without
      audience metadata) are redacted into an opaque [board_changed]
      invalidation frame, and signed-out, disabled, or deleted principals are
      disconnected promptly. Reconnects carrying [Last-Event-ID] replay
      projected visible deliveries and emit an explicit
      [observer_resync_required] event on replay gaps. Because this stream is
      not an MCP registered client ([client_id = None]), upstream {!Sse} also
      withholds [Operator_only]/[Keeper_only] private [lane_addons] deliveries
      fail-closed; clients observe shared invalidations and refetch authorized
      HTTP projections. *)

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

(** Whether [caller] may read Keeper-scoped memory diffs for [keeper]:
    strictly requires that [caller] owns [keeper] in [state]. *)
val can_read_keeper_memory
  :  state:Authz_state.t
  -> Auth_gate.authenticated
  -> keeper:string
  -> bool

(** Whether [caller] may read Keeper-scoped sandbox telemetry for [keeper]:
    permits [Admin] or the owner of [keeper] in [state]. *)
val can_read_keeper_sandbox
  :  state:Authz_state.t
  -> Auth_gate.authenticated
  -> keeper:string
  -> bool

(** Per-principal SSE visibility predicate for {!observer_events_path}.
    Private Keeper chat/AG-UI/turn-preview events are restricted strictly to
    the Keeper's owner in [state]; operator-only events require [Admin];
    [lane_addons] visibility fields are enforced fail-closed; raw
    [notifications/board] payloads (anything richer than opaque
    [board_changed]) return [false] fail-closed so [Direct] titles and previews
    can never pass verbatim. *)
val observer_event_visible_to
  :  state:Authz_state.t
  -> Auth_gate.authenticated
  -> Yojson.Safe.t
  -> bool

(** Projects a single replayed or live SSE delivery for [caller] on
    {!observer_events_path}. Any [notifications/board] payload (including
    [Direct] posts, comments, votes, reactions, and post changes) is redacted
    to an opaque [board_changed] invalidation frame preserving [event_id] with
    zero title, content preview, author, or post-id fields so clients refetch
    through {!board_reader_of}. All other events return [Some frame] iff
    {!observer_event_visible_to} permits them, else [None]. *)
val project_observer_event
  :  state:Authz_state.t
  -> Auth_gate.authenticated
  -> event_id:int
  -> frame:string
  -> payload:Yojson.Safe.t
  -> string option

(** Strips single-user auth headers ([Authorization], [Cookie],
    [X-Masc-Internal-Token], [X-Masc-Agent], [X-Masc-Agent-Name],
    [X-Gate-Agent]) and spoofable actor/token query parameters ([agent],
    [agent_name], [me], [token], [access_token]) before passing an already
    {!Auth_gate}-authorized request to shared projections. *)
val strip_single_user_auth_headers : Httpun.Request.t -> Httpun.Request.t

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
