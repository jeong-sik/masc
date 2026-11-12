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
(** Capture the workspace scope before any yielding read and retain its
    [observer_instance_id] in the response. While the execution owner has no
    successful observation, the initial bounded warm window returns the
    canonical initializing envelope. Clients retain read debt until canonical
    completion, rather than polling this envelope.

    A successful cached Shell answers immediately and starts the existing
    bounded asynchronous refresh. Without a Shell seed, one bounded request
    attempts it and falls back to this scope's last-good/bootstrap data.
    Successful warm, cold and asynchronous fills install through
    [publish_shell_cache_success], after updating the read cache, so they also
    announce canonical namespace completion. Retired fills cannot seed another
    scope. All responses retain the canonical surface/source/retention fields.

    These request recovery paths do not own source-triggered Shell recompute;
    the atomic Shell controller publishes through the same installation API. *)

val namespace_truth_snapshot_from_caches :
  Mcp_server.server_state -> Yojson.Safe.t option
(** [namespace_truth_snapshot_from_caches state] composes a
    lightweight namespace-truth snapshot from cached refs only —
    no PG I/O.

    Returns [None] while execution warms or its scope was replaced during
    assembly. A read retains one immutable cache source and its typed read
    completeness together; partial/error observations also publish readable
    rows with the shared [projection_diagnostics.read_completeness/read_error]
    fields and do not masquerade as complete readiness.
    The canonical publisher additionally revalidates it before fanout.
    Otherwise reads the
    proactive execution cache + last-good shell (or bootstrap shell
    when no last-good shell exists yet) + empty command summary and
    composes via
    {!Server_dashboard_http_namespace_truth_support.compose_namespace_truth_snapshot}.

    No shell refresh is performed on this path. *)

val broadcast_namespace_truth_snapshot :
  Mcp_server.server_state -> unit
(** [broadcast_namespace_truth_snapshot state] dedup-broadcasts the
    current snapshot to the captured workspace and instance Observer sessions.

    One SSE channel per broadcast, [type] = ["project_snapshot"]. It used to
    emit a second, ["namespace_truth_snapshot"], carrying the identical
    payload; every consumer handled both names in the same branch, so the
    fanout said one thing twice (#27664).

    Dedup compares the captured scope, structural snapshot hash (excluding
    generation timestamps) and cache-completion revision. Equal-valued Shell
    completion is still published so an initializing reader can settle.
    Only a committed replay receipt advances this state; a failed insertion
    remains retryable. [observer_instance_id] comes from the captured scope.

    Log demotion: "pushed via SSE" log goes to DEBUG when no Observer
    is connected (avoids per-minute housekeeping noise; was log-flood
    96/min in fresh-server logs).

    Safe to call from any fiber — reads cached refs only. *)

(** {1 Test-visible dedup state}
    Pinned for behaviour-tests under
    {!test/test_dashboard_namespace_truth} which need to reset the
    dedup cache between scenarios. *)

val last_namespace_truth_snapshot_hash :
  Agent_core_sha256.t option ref
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
