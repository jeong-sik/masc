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
  sw:'a ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  'b ->
  Yojson.Safe.t
(** [dashboard_namespace_truth_http_json ~state ~sw ~clock request]
    serves the namespace-truth read model.

    Cold-start fast-path: when the proactive
    {!Server_dashboard_http_execution_surfaces._execution_cache} has
    not produced a successful first cycle and the warm-escape window
    (default 90s = 75s refresh timeout + 15s slack, capped via
    [MASC_DASHBOARD_EXECUTION_REFRESH_TIMEOUT_S]) has not elapsed,
    returns:

    {[
      \{"status": "initializing", "generated_at": ..., "message": ...\}
    ]}

    Warm path: composes shell + execution + command summaries with
    per-fiber timeouts:

    | Env var | Default | Used for |
    | --- | --- | --- |
    | [MASC_NAMESPACE_TRUTH_WARM_TIMEOUT_S] | 8.0s | base warm |
    | [MASC_NAMESPACE_TRUTH_COLD_TIMEOUT_S] | 15.0s | base cold |
    | [MASC_NAMESPACE_TRUTH_SHELL_FIBER_TIMEOUT_S] | 12.0s | shell warm cap |
    | [MASC_NAMESPACE_TRUTH_COLD_SAFETY_MARGIN_S] | 4.0s | cold shell safety |

    Shell timeout (cold) = max(cold_timeout, shell_fiber + safety) —
    must exceed the inner cache timeout to avoid the double-timeout
    race that discards stale data (#5090).

    Graceful degradation: shell falls back to
    {!Server_dashboard_http_core._last_good_shell} on timeout (61x/day
    zero-out under I/O contention before the fix). *)

val namespace_truth_snapshot_from_caches :
  Mcp_server.server_state -> Yojson.Safe.t option
(** [namespace_truth_snapshot_from_caches state] composes a
    lightweight namespace-truth snapshot from cached refs only —
    no PG I/O.

    Returns [None] iff the execution cache has not produced its
    first successful result (cold start).  Otherwise reads the
    proactive execution cache + last-good shell + empty command
    summary and composes via
    {!Server_dashboard_http_namespace_truth_support.compose_namespace_truth_snapshot}.

    Side effect: updates {!Server_dashboard_http_core._last_good_shell}
    on a fresh shell read. *)

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

val _last_namespace_truth_snapshot_hash :
  Digestif.SHA256.t option ref
(** [_last_namespace_truth_snapshot_hash] is the dedup state for
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
    broadcast hash; updates {!_last_namespace_truth_snapshot_hash}
    as a side effect.  Pinned at the dedup-contract seam. *)
