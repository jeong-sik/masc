(** Server_dashboard_http_namespace_truth — namespace-truth read
    model and SSE snapshot broadcasting.

    Three external surfaces:
    - {!dashboard_namespace_truth_http_json}: the
      [/dashboard/namespace-truth] HTTP handler (direct caller:
      [Server_dashboard_http.dashboard_namespace_truth_http_json]).
    - {!namespace_truth_snapshot_from_caches}: lightweight cached
      snapshot used by runtime bootstrap.
    - {!broadcast_namespace_truth_snapshot}: SSE broadcast to
      Observer sessions, called from bootstrap loops and proactive
      refresh hooks.

    Internal: env-default helpers, hash-based dedup state, module
    aliases (Execution_surfaces / Namespace_truth_support).  All
    private — the module's effect-free contract is "compose a
    cached read-model + dedup-broadcast it; everything else is
    plumbing". *)

val dashboard_namespace_truth_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  'b ->
  Yojson.Safe.t
(** [dashboard_namespace_truth_http_json ~state ~sw ~clock request]
    serves the namespace-truth read model.

    All responses, including cold-start, carry top-level
    [dashboard_surface], [dashboard_aliases], [source], [retention],
    and [generated_at_iso] fields so legacy aliases such as
    [/dashboard/room-truth] remain visibly tied to the canonical
    namespace-truth read model.

    Cold-start fast-path: when the proactive
    {!Server_dashboard_http_execution_surfaces.execution_cache} has
    not produced a successful first cycle and the warm-escape window
    (default 90s = 75s refresh timeout + 15s slack, capped via
    [MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S]) has not elapsed,
    returns:

    {[
      \{"status": "initializing", "generated_at": ..., "message": ...\}
    ]}

    Warm path: once {!Server_dashboard_http_core.last_good_shell}
    exists, composes the HTTP response from cached shell + proactive
    execution state immediately and forks a bounded shell refresh in
    the request switch (stale-while-revalidate).  The refresh timeout
    is 5.0s (module-level constant [namespace_truth_shell_refresh_timeout_s]
    in the .ml).

    First seed: when no last-good shell exists yet, does one bounded
    synchronous shell attempt before composing shell + execution +
    command summaries with per-fiber timeouts.  The four timeout
    constants (warm 8.0s, cold 15.0s, shell-fiber cap 12.0s, cold
    safety margin 4.0s) were previously tunable via
    [MASC_NAMESPACE_TRUTH_*_TIMEOUT_S] env vars; RFC-0138 Phase 3
    Step 4 (#16752) retired those knobs because Step 3 (#16738)
    wired /project-snapshot through {!Dashboard_snapshot}, so this
    fallback path is taken at most once per process lifetime
    (cold-start before the refresh fiber's first publish) and no
    longer carries steady-state load worth tuning.  See the
    module-level [namespace_truth_*_timeout_s] bindings in the .ml
    for the current values.

    Shell timeout (cold) = max(cold_timeout, shell_fiber + safety) —
    must exceed the inner cache timeout to avoid the double-timeout
    race that discards stale data (#5090).

    First-seed graceful degradation: shell falls back to
    {!Server_dashboard_http_core.last_good_shell} on timeout (61x/day
    zero-out under I/O contention before the fix). *)

val namespace_truth_snapshot_from_caches :
  Mcp_server.server_state -> Yojson.Safe.t option
(** [namespace_truth_snapshot_from_caches state] composes a
    lightweight namespace-truth snapshot from cached refs only —
    no PG I/O.

    Returns [None] iff the execution cache has not produced its
    first successful result (cold start).  Otherwise reads the
    proactive execution cache + last-good shell (or bootstrap shell
    when no last-good shell exists yet) + empty command summary and
    composes via
    {!Server_dashboard_http_namespace_truth_support.compose_namespace_truth_snapshot}.

    No shell refresh is performed on this path. *)

val broadcast_namespace_truth_snapshot :
  Mcp_server.server_state -> unit
(** [broadcast_namespace_truth_snapshot state] dedup-broadcasts the
    current snapshot to all Observer SSE sessions.

    Three SSE channels emitted per broadcast (snapshot payload
    identical):

    | [type] field | Stream alias |
    | --- | --- |
    | ["project_snapshot"] | canonical |
    | ["namespace_truth_snapshot"] | alias for namespace dashboards |
    | ["room_truth_snapshot"] | legacy compatibility |

    Dedup: SHA-256 of the serialized snapshot (with [generated_at]
    stripped recursively before hashing).  When the hash matches the
    previous broadcast, skips with a debug log.

    Log demotion: "pushed via SSE" log goes to DEBUG when no Observer
    is connected (avoids per-minute housekeeping noise; was log-flood
    96/min in fresh-server logs).

    Safe to call from any fiber — reads cached refs only. *)

(** {1 Test-visible dedup state}
    Pinned for behaviour-tests under
    {!test/test_dashboard_namespace_truth} which need to reset the
    dedup cache between scenarios. *)

val last_namespace_truth_snapshot_hash :
  Digestif.SHA256.t option ref
(** [last_namespace_truth_snapshot_hash] is the dedup state for
    {!broadcast_namespace_truth_snapshot}.  Holds the SHA-256 of
    the most recently broadcast snapshot (with [generated_at]
    stripped) or [None] when nothing has been broadcast yet.
    Tests reset to [None] to force re-broadcast in scenarios
    that exercise the dedup path. *)

val should_broadcast_namespace_truth_snapshot :
  Yojson.Safe.t -> bool
(** [should_broadcast_namespace_truth_snapshot snapshot] computes
    the SHA-256 of the [generated_at]-stripped form of [snapshot]
    and returns [true] iff it differs from the previously
    broadcast hash; updates {!last_namespace_truth_snapshot_hash}
    as a side effect.  Pinned at the dedup-contract seam. *)
