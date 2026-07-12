(** RFC-0138 Phase 3 — dashboard read path selectors.

    Steps 1+2+3 published a [Dashboard_snapshot]-first read path for
    four projections: [/shell], [/tools], [/telemetry/summary], and
    [/project-snapshot] (+ alias [/namespace-truth]).
    Step 5 of the migration sequence renamed this module from
    [Server_dashboard_shell_snapshot] to [Server_dashboard_snapshot_select]
    and retired [Dashboard_cache] from the cold-start fallback in
    [select_telemetry_summary_json] (the path runs at most once per
    process before the refresh fiber publishes).  A later pass also
    retired [Dashboard_cache] from [select_project_snapshot_json],
    leaving this module free of cache-layer dependencies.

    [Server_dashboard_http_core] cannot host these helpers because
    [Dashboard_snapshot] already calls into [Server_dashboard_http_core]
    for its refresh-fiber compute path; placing the selectors here
    keeps the dependency arrows acyclic:

      [Server_routes_http_routes_dashboard]
        -> [Server_dashboard_snapshot_select]
             -> [Dashboard_snapshot]                  (lock-free read)
             -> [Server_dashboard_http_core]          (shell fallback)
             -> [Server_dashboard_http_runtime_info]  (tools fallback)
             -> [Telemetry_unified]                   (telemetry fallback) *)

val select_shell_json :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?request:Httpun.Request.t ->
  ?timing:Server_timing.t ->
  ?light:bool ->
  Workspace.config ->
  Yojson.Safe.t
(** Returns [Dashboard_snapshot.current ()].shell when the refresh
    fiber has published (wait-free, [O(1)]).  Falls back to the
    synchronous [Server_dashboard_http_core.dashboard_shell_http_json]
    compute path when:

    - [~light:true] — the snapshot stores only the canonical shape;
      the trimmed variant continues through [Dashboard_cache] for one
      sprint per RFC-0138 §3.3 Step 1 (retire criterion: snapshot grows
      a [Light] arm or callers stop requesting light).
    - [Dashboard_snapshot.current ()] is [None] — first request after
      a cold start, before the refresh fiber has emitted.  The
      synchronous compute is paid exactly once per process lifetime.

    The snapshot-hit branch records a [snapshot_read] phase in
    [~timing] so the [Server-Timing] header lets us measure the p99
    retire criterion ("snapshot_read;dur~0ms p99 for /shell"). *)

val select_tools_json :
  ?actor:string ->
  ?timing:Server_timing.t ->
  ?include_sensitive:bool ->
  ?fresh_keeper_waiting_inventory:bool ->
  Workspace.config ->
  Yojson.Safe.t
(** RFC-0138 Phase 3 Step 2 — /api/v1/dashboard/tools read path
    selector.  Returns [Dashboard_snapshot.current ()].tools when the
    refresh fiber has published AND [~actor] is omitted (the snapshot
    stores the canonical full registry view, not per-agent filtered
    catalogues).  Falls back to
    [Server_dashboard_http_runtime_info.dashboard_tools_http_json]
    otherwise. [?include_sensitive] is an explicit authenticated-operator
    decision and defaults to the redacted projection. On a snapshot hit, opting
    in replaces the redacted waiting inventory with a fresh sensitive projection
    without recomputing the rest of the tools payload. A snapshot whose
    visibility does not match the request is also replaced at this boundary, so
    a public caller cannot inherit an operator projection. When
    [?fresh_keeper_waiting_inventory] is true, only that queue/waiting field is
    recomputed and replaced after the snapshot read; this preserves the
    wait-free tools base while allowing revision-bearing queue invalidations to
    converge immediately instead of rereading an older two-second snapshot.

    Per RFC-0138 §3.3 Step 2 the per-actor variant continues through
    [Dashboard_cache] until the snapshot type grows an [Actor_filter]
    arm; retire criterion is the [Server-Timing snapshot_read;dur~0ms]
    p99 on the actor-less call path. *)

val select_telemetry_summary_json :
  ?timing:Server_timing.t ->
  Workspace.config ->
  Yojson.Safe.t
(** RFC-0138 Phase 3 Step 2 — /api/v1/dashboard/telemetry/summary read
    path selector.  Returns [Dashboard_snapshot.current ()].telemetry_summary
    when the refresh fiber has published.  Falls back to a direct
    [Telemetry_unified.summary_json] call when the snapshot slot is
    empty — bootstrap path is paid at most once per process lifetime.

    Step 5 (#16761) retired the prior [Dashboard_cache.get_or_compute]
    wrapper around the fallback compute: the cache provided TTL +
    single-flight dedup that the refresh-fiber publish path no longer
    needs and the per-process once-only cold-start does not benefit
    from. *)

val select_project_snapshot_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?timing:Server_timing.t ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** RFC-0138 Phase 3 Step 3 — /project-snapshot (+ alias
    /namespace-truth) read path selector.

    Returns [Dashboard_snapshot.current ()].namespace_truth when the
    refresh fiber has populated it (refresh_loop must be invoked with
    [~state] — see [Dashboard_snapshot.refresh_loop]).  Falls back to
    [Server_dashboard_http_namespace_truth.dashboard_namespace_truth_http_json]
    in two cases:

    - [Dashboard_snapshot.current ()] is [None] — cold start before
      first refresh tick.
    - The snapshot exists but [.namespace_truth = `Null] — refresh
      fiber ran without [~state] (older boot path) OR the
      cached-refs read returned [None] (execution cache not yet
      hydrated).

    Retire criterion (RFC-0138 §3.3 Step 3): Server-Timing
    "snapshot_read;dur~0ms" p99 on /project-snapshot.  Step 4
    retires the 6 [MASC_NAMESPACE_TRUTH_*_TIMEOUT_S] env knobs once
    the fallback compute branch is unused. *)
