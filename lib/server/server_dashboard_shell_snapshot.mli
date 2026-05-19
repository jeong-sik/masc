(** RFC-0138 Phase 3 Step 1 — /shell read path selector.

    [Server_dashboard_http_core] cannot host this helper because
    [Dashboard_snapshot] already calls into [Server_dashboard_http_core]
    for its refresh-fiber compute path; placing the selector here keeps
    the dependency arrows acyclic:

      [Server_routes_http_routes_dashboard]
        -> [Server_dashboard_shell_snapshot]
             -> [Dashboard_snapshot]   (read slot, lock-free)
             -> [Server_dashboard_http_core]  (fallback compute) *)

val select_shell_json :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?request:Httpun.Request.t ->
  ?timing:Server_timing.t ->
  ?light:bool ->
  Coord.config ->
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
