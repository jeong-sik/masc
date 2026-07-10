(** Server_routes_http_runtime — runtime route handlers for the
    HTTP/1.1 listener (health / liveness / readiness / OPTIONS) +
    shared helpers used by sister route modules.

    Open'd by {!Server_routes_http_routes_frontend} and
    {!Server_routes_http_routes_activity} so all top-level
    bindings are part of the public surface.  The Http module
    alias stays private. *)

val is_dashboard_spa_deep_link : string -> bool
(** [is_dashboard_spa_deep_link path] returns [true] iff [path]
    is a dashboard SPA deep link that should be served by the
    SPA shell rather than rejected as 404.

    Three rules pinned at the contract seam:
    - starts with [/dashboard/]
    - NOT a [/dashboard/assets/] path (those have their own
      asset handler)
    - NOT [/dashboard/credits] (which has a dedicated handler)

    A future "let's add /dashboard/api/..." route reopens this
    classification — pinning so the SPA fallback does not
    accidentally swallow API routes. *)

(** {1 CORS} *)

val cors_preflight_headers : string -> (string * string) list
(** [cors_preflight_headers origin] returns the 4-header
    CORS preflight response for [OPTIONS] requests:
    [access-control-allow-origin] / [-allow-methods]
    ([GET, POST, DELETE, OPTIONS]) / [-allow-headers] /
    [-expose-headers] ([Mcp-Session-Id, Mcp-Protocol-Version]).
    Pinned method set + exposed headers are the operator-visible
    contract — runbook integrations key off these literals. *)

(** {1 JSON-RPC error envelope} *)

val json_rpc_error : Mcp_error_code.t -> string -> string
(** [json_rpc_error code message] returns the canonical
    JSON-RPC 2.0 error envelope as a string:
    [{"jsonrpc":"2.0","error":{"code":<code>,"message":"<msg>"},"id":null}].
    Delegates to {!Mcp_error_code.jsonrpc_error_body}.
    Message is `String.escaped`-quoted; callers must not pre-
    escape. *)

val is_http_error_response : Yojson.Safe.t -> bool
(** [is_http_error_response json] returns [true] when [json] is
    a JSON-RPC 2.0 response with [id = null] AND [error.code]
    is {!Mcp_error_code.Parse_error} or {!Mcp_error_code.Invalid_request}.
    Mirrors the predicate in
    {!Server_mcp_transport_http_headers}; duplicated here
    because the route layer needs it before the transport
    headers module is reachable. *)

(** {1 Server uptime} *)

val server_start_time : float
(** Captured at module init via {!Unix.gettimeofday}.  The
    [/health] endpoint computes uptime as
    [now - server_start_time].  Pinned as a float because the
    health renderer formats with second precision (no micro). *)

val configured_http_port : unit -> int
val configured_http_host : unit -> string
(** Aliases over {!Env_config_core.masc_http_port_int} /
    {!Env_config_core.masc_host}.  Each call re-reads the env
    var, supporting tests that override mid-process. *)

val advertised_host_port :
  Httpun.Request.t -> string * int
(** [advertised_host_port request] returns the
    [(canonical_host, port)] pair the server should advertise
    in JSON projections.  Reads the [Host:] header (if present)
    via {!parse_host_port}, then routes the host through
    {!Transport_read_model.normalize_advertised_host} (loopback
    aliases collapse to the configured default).  Falls back to
    [(configured_http_host (), configured_http_port ())] when
    the header is absent. *)

val advertised_base_url : Httpun.Request.t -> string
(** [advertised_base_url request] returns the browser-visible HTTP(S) base URL.
    It derives the authority from [Host:] and the scheme from
    [X-Forwarded-Proto] / [Forwarded: proto=...] when present, falling back to
    local [http]. *)

(** {1 Discovery / status JSON} *)

val websocket_discovery_json : Httpun.Request.t -> Yojson.Safe.t
(** [websocket_discovery_json request] returns the WebSocket
    discovery payload using {!advertised_host_port}.  Always
    sets [include_configured = true] so dashboards see the
    enabled / runtime-listening pair.  Used by [GET /ws.json]
    on both HTTP/1.1 and HTTP/2 listeners. *)

val transport_json : Httpun.Request.t -> Yojson.Safe.t
(** [transport_json request] returns the full transport status
    JSON (HTTP + WS + protocol set).  Sub-projection used by
    {!make_health_json}'s [transport] field. *)

val agent_card_json : Httpun.Request.t -> Yojson.Safe.t
(** [agent_card_json request] returns the public well-known MASC server
    card served from [/.well-known/agent.json].  This route is public
    discovery metadata; mutable operations still require normal tool auth. *)

(** {1 Runtime subsystem helpers} *)

(** {1 Health endpoints} *)

val health_path_diagnostics :
  unit -> Server_base_path_diagnostics.t
(** [health_path_diagnostics ()] resolves the base-path
    diagnostics for the [/health] response.  When the runtime
    state is initialised, reads from
    [state.workspace_config.base_path]; otherwise falls back to the
    default base path computed from env. *)

val make_health_json :
  ?listener:string -> ?section_timings_ref:(string * int) list ref -> Httpun.Request.t -> Yojson.Safe.t
(** [make_health_json ?listener request] builds the full health diagnostics
    JSON body.  [listener] defaults to ["http/1.1"] and is overridden to
    ["h2"] by the H2 gateway.  This is the force-compute diagnostic builder
    used by tests and snapshot refreshes.  The public [/health] route uses
    {!make_health_response_json}; callers request cached full diagnostics with
    [/health?full=1].

    {2 Top-level keys (operator-visible contract)}

    [status] / [server] / [version] / [release_version] /
    [build] / [protocol] (default + listener + supported list) /
    [transport] / [paths] / [internal_mcp_auth] / [uptime] /
    [sse_clients] / [startup] / [subsystems] / [feature_flags] / [gc] /
    [overall_status] / [operator_action_required] /
    [operator_action_reasons] /
    [keeper_fibers] / [keeper_fd_pressure] / [fd_accountant] /
    [keeper_fleet_safety] / [keeper_reaction_ledger] / [paused_keepers] /
    [keeper_config_parse_error_count] / [keeper_config_parse_errors] /
    [keeper_config_unknown_key_count] / [keeper_config_unknown_keys] /
    [keeper_config_schema_status] / [keeper_config_schema_blocking] /
    [keeper_config_schema_terminal_reason] /
    [keeper_config_operator_action_required] /
    [lazy_task_boot_guard_fires_total].

    [status] is the HTTP OK envelope/readiness status.  Full-health
    operator diagnostics are summarized by [overall_status],
    [operator_action_required], and [operator_action_reasons], so a live
    server can remain probe-OK while still surfacing degraded keeper fleet
    state at the top level.

    {2 paused_keepers contract}

    [paused_keepers.count] and [paused_keepers.names] are the union of
    registry-visible paused keepers and durable [.masc/keepers/*.json]
    metas with [paused = true].  The nested [registry_paused_*] and
    [durable_*] fields keep the two sources inspectable so a keeper
    that has been auto-paused and removed from the live keepalive set
    does not disappear from [/health].  [running_*] remains as a legacy
    alias for [registry_paused_*]; it does not mean FSM phase [Running].
    [autoboot_enabled_*] and [details] distinguish auto-recoverable,
    operator-paused, and reconcile-gated durable pauses without auto-unpausing
    them.  [missing_pause_root_cause] is true when a keeper is auto-recoverable
    but its persisted runtime has no typed [last_blocker].  [read_error_count]
    surfaces corrupt durable meta instead of silently reporting a clean zero.

    {2 keeper_fd_pressure and keeper_fleet_safety contract}

    [keeper_fd_pressure] exposes the effective process [nofile] soft
    limit, currently open FD count when available, the host kernel file-table
    snapshot when available, projected 24-Keeper budget, and the admission
    decision used by the FD guard.  This lets operators distinguish "shell
    says the host limit is high" from the actual runtime inherited by the
    server process, and distinguish process-local EMFILE from host-wide ENFILE.

    [fd_accountant] exposes the live resource accountant snapshot used by the
    shared spawn/HTTP/log backpressure layer: process FD open/limit readings,
    whether FD pressure is active, and each resource kind's in-flight,
    configured-concurrency, and effective-concurrency counts.

    [keeper_fleet_safety] compares configured, unpaused autoboot-enabled
    keepers with the live healthy-running keeper fiber count while separately
    reporting durable paused keepers via [paused_autoboot_enabled_*] and
    bootable keepers via [bootable_keeper_*].  It distinguishes
    [running_keeper_fiber_count] / [healthy_running_keeper_fiber_count] from
    [failing_keeper_fiber_count] and [executable_keeper_fiber_count] because
    the FSM intentionally allows [Failing] keepers to finish or attempt turns.
    It reports [blocked] when autoboot-enabled keepers exist but no executable
    fiber remains, and [degraded] when executable fibers remain but healthy
    running capacity is zero, below the safety margin, or below
    [target_reaction_capacity_count].
    [paused_autoboot_enabled_keeper_count] keeps operator-paused autoboot
    keepers visible without counting them as reaction-capacity targets.

    [keeper_reaction_ledger] summarizes recent durable stimulus -> reaction
    rows per keeper.  It reports [degraded] when a persisted stimulus has no
    later reaction/cursor/receipt row in the scanned window, making a stopped
    reaction chain visible without scraping keeper-local JSONL files.

    {2 lazy_task_boot_guard_fires_total contract (P2 silent-
    failure fix)}

    Surfaces {!Otel_metric_store.metric_total} for
    [masc_lazy_task_boot_guard_fired_total].  Without this
    field, an operator hitting [/health] would see ["status":
    "ok"] while keepers had silently failed to start.  Pinning
    at the contract seam: a future "drop unused metric" PR
    must touch this. *)

val make_health_probe_json :
  ?listener:string -> Httpun.Request.t -> Yojson.Safe.t
(** [make_health_probe_json ?listener request] builds the cheap default
    [/health] probe body.  It keeps liveness/readiness-facing fields such as
    [startup], [paths], [transport], [logs], and quick GC counters, but skips
    durable keeper scans, reaction-ledger JSONL reads, config TOML scans, and
    contract-verdict ledger inspection. *)

val make_health_response_json :
  ?listener:string -> Httpun.Request.t -> Yojson.Safe.t
(** [make_health_response_json ?listener request] is the public [/health]
    renderer.  It returns {!make_health_probe_json} by default.  When the
    request query contains [full=1] / [full=true], it returns the latest cached
    full-health snapshot plus cheap request-local fields and marks the snapshot
    for refresh when it is missing or stale.  The HTTP handler must not
    synchronously run durable keeper scans; the Eio refresh loop started by
    {!start_full_health_snapshot_refresh_loop} performs those scans. *)

val start_full_health_snapshot_refresh_loop :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** Starts the Eio background refresh loop for cached [/health?full=1]
    diagnostics.  The loop keeps heavy durable scans out of the HTTP request
    path and stores stale/error metadata when refreshes fail or time out. *)

module For_testing : sig
  val reset_full_health_snapshot : unit -> unit
  (** Clears the cached full-health snapshot and in-flight refresh marker. *)

  val refresh_full_health_snapshot_now :
    ?listener:string -> Httpun.Request.t -> unit
  (** Synchronously recomputes and stores the cached full-health snapshot. *)

  val mark_full_health_snapshot_error : exn -> unit
  (** Records a failed background refresh without recomputing the snapshot. *)

  val full_health_refresh_timing : unit -> float * float * float
  (** Returns [(interval_sec, timeout_sec, ttl_sec)] for full-health refresh. *)
end

val keeper_fleet_runtime_resolution_fields : unit -> (string * Yojson.Safe.t) list
(** [keeper_fleet_runtime_resolution_fields ()] returns the health/fleet
    safety subset projected into [/api/v1/dashboard/shell]'s
    [runtime_resolution].  It intentionally flattens
    [paused_keepers] to a count for the dashboard shell health chip while
    [/health] keeps the richer paused keeper object.  The
    [keeper_reaction_ledger] field keeps the same summary object as
    [/health] so the dashboard can render pending durable stimuli without a
    second endpoint.  [keeper_turn_admission] mirrors the [/health] admission
    pressure component so the shell can show in-flight lane, chat waiting
    count/cap/full state, and rejected-chat counters without polling a second
    endpoint.  [keeper_board_event_collection] mirrors the [/health] board
    scanner failure component so the shell can show a reactive-board ingestion
    fault without scraping logs or metrics.  [fd_accountant] is also projected here so the dashboard shell
    can show the same backpressure source as [/health] without scraping
    Otel_metric_store. *)

val keeper_fleet_runtime_resolution_light_fields :
  unit -> (string * Yojson.Safe.t) list
(** Like {!keeper_fleet_runtime_resolution_fields}, but omits the
    reaction-ledger JSONL scan for the [/api/v1/dashboard/shell?light=true]
    header hot path.  It keeps [keeper_turn_admission] because admission
    pressure is in-memory and cheap to read, and keeps
    [keeper_board_event_collection] because the failure snapshot is in-memory
    and cheap to read. *)

val health_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [health_handler request reqd] writes {!make_health_response_json} as the
    response body. *)

val liveness_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [liveness_handler request reqd] always responds [200] as
    soon as the HTTP accept loop is running.  Does NOT depend
    on server_state initialisation — Kubernetes / Railway
    liveness probe target.  Body:
    [{"live": true, "startup": <Server_startup_state.to_yojson>}]. *)

val readiness_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [readiness_handler request reqd] responds [200] only when
    [Server_startup_state.state_ready] is [true].

    | State | HTTP status | Body fields |
    |---|---|---|
    | ready | [200 OK] | [ready: true], [phase], [backend_mode] |
    | not ready | [503 Service Unavailable] | [ready: false], [phase], [elapsed_sec] |

    Pinned at the contract seam — orchestrators (k8s, Railway)
    key off the [200] vs [503] distinction. *)

(** {1 Board} *)

val board_post_detail_json :
  include_moderation:bool ->
  blind_votes:bool ->
  config:Workspace.config option ->
  voter:string option ->
  reaction_actor:string option ->
  response_format:string ->
  post_id:string ->
  [> `OK | `Not_found ] * string
(** [board_post_detail_json ~voter ~reaction_actor ~response_format ~post_id] returns
    [(status, json_string)] for [GET /api/v1/board/<post_id>].
    When [voter] is supplied, post/comment rows include vote state for
    that voter. [reaction_actor] independently selects the actor-aware
    reaction state and must come from authenticated credential identity,
    never a query parameter. When [include_moderation] is [true], rows also
    include operator-only moderation projection fields. When [config] is
    supplied, post rows include contributor-quality projection fields.
    When [blind_votes] is [true], rows hide score fields until that
    voter has voted.

    {2 response_format values (case-insensitive, trimmed)}

    | Format | Shape |
    |---|---|
    | [["flat"]] | post fields + [comments] sibling |
    | otherwise (default [["nested"]]) | [{"post": ..., "comments": [...]}] |

    {2 Status / body}

    | Outcome | Status | Body |
    |---|---|---|
    | Post missing | [404 Not Found] | [{"error":"Post not found: <id>"}] |
    | Found | [200 OK] | per response_format |

    Comment fetch errors (rare) silently degrade to empty
    comment list rather than failing the whole response. *)

(** {1 OPTIONS} *)

val options_handler : Httpun.Request.t -> Httpun.Reqd.t -> unit
(** [options_handler request reqd] handles [OPTIONS *] and
    [OPTIONS <path>] CORS preflights.  Always responds
    [204 No Content] with {!cors_preflight_headers} for the
    request origin and [content-length: 0]. *)
