(** Server_dashboard_http_execution_surfaces — cached
    execution + transport-health dashboard surfaces.

    [Server_dashboard_http] does
    [include Server_dashboard_http_execution_surfaces];
    [server_dashboard_http_namespace_truth.ml] does
    [module Execution_surfaces = ...] alias and reaches
    {!_execution_cache} +
    {!_broadcast_namespace_truth_ref} through it.  Plus
    direct dotted callers and a
    [let module S = ...] inline alias in
    [test/test_types.ml] for the
    lifecycle-event patcher family.

    External surface (17 entries):
    - {b cache cells} ({!_execution_cache},
      {!_broadcast_namespace_truth_ref}) reached by
      [server_dashboard_http_namespace_truth] for
      readiness gating + truth-broadcast wiring.
    - {b shell prewarm} ({!warm_shell_cache}) — called
      at server bootstrap.
    - {b dashboard actor resolution}
      ({!execution_actor_for_request}).
    - {b cache management}
      ({!invalidate_execution_cache},
      {!patch_keeper_dependent_caches}).
    - {b refresh fibers}
      ({!start_execution_refresh_loop},
      {!start_transport_health_refresh_loop}).
    - {b snapshot accessors}
      ({!dashboard_execution_snapshot_json},
      {!dashboard_transport_health_snapshot_json}).
    - {b HTTP route entries}
      ({!dashboard_execution_http_json},
      {!dashboard_execution_trust_http_json},
      {!dashboard_transport_health_http_json}).
    - {b lifecycle-event patchers}
      ({!keepalive_running_of_lifecycle_event},
      {!phase_of_lifecycle_event},
      {!pipeline_stage_of_lifecycle_event},
      {!paused_of_lifecycle_event}) — pinned because
      [test/test_types] inline-aliases this module to
      assert every SSOT keeper-lifecycle event is
      handled (#8396).

    Internal helpers stay private at this boundary
    (~15 internal lets — [shell_prewarm_timeout_s],
    [_last_broadcast_hash] /
    [_broadcast_hash_mu] / [broadcast_cached_surface],
    [_transport_health_cache],
    [keeper_agent_status_opt] / [patched_keeper_status]
    / [patch_keeper_row] / [patch_keeper_rows]
    SSE-event row patcher family,
    [running_keeper_names] /
    [patch_surface_json_for_running_keepers],
    [patch_execution_cache_for_keeper] /
    [patch_operator_snapshot_cache_for_keeper],
    [transport_health_cache_diagnostics]). *)

(** {1 Cache cells} *)

val _execution_cache : Server_dashboard_http_cache.cached_surface
(** Cached execution surface JSON.  Reached by
    [Server_dashboard_http_namespace_truth] (via the
    [Execution_surfaces] alias) for readiness gating —
    the namespace-truth refresh skips the live execution
    fetch when this cache is still serving a successful
    snapshot. *)

val _broadcast_namespace_truth_ref :
  (Mcp_server.server_state -> unit) ref
(** Forward reference for the namespace-truth broadcast.
    [Server_dashboard_http_namespace_truth] sets this at
    boot so the cache patchers above can broadcast
    truth updates without a circular dependency.  Read
    via the [Execution_surfaces] alias inside
    [namespace_truth.ml]. *)

(** {1 Shell prewarm} *)

val warm_shell_cache : Mcp_server.server_state -> unit
(** Materializes the shell-state cache at server boot so
    the first dashboard request does not pay the cold
    fetch.  Atomically gates against re-entrancy. *)

(** {1 Dashboard actor resolution} *)

val execution_actor_for_request :
  base_path:string -> Httpun.Request.t -> string option
(** Returns the dashboard actor name attributed to a
    request via [Server_auth.sanitized_dashboard_actor_for_request].
    Threaded into compute calls so the operator audit
    log records who initiated each fetch. *)

(** {1 Cache management} *)

val invalidate_execution_cache : unit -> unit
(** Drops the cached execution surface so the next
    snapshot read recomputes from upstream.  Swallows
    [Eio.Cancel.Cancelled] re-raise plus logs and counts other
    exceptions through
    {!Prometheus.metric_keeper_lifecycle_callback_failures}. *)

val invalidate_execution_cache_with_hooks_for_testing :
  invalidate_execution_surface:(unit -> unit) ->
  invalidate_light_cache:(unit -> unit) ->
  unit ->
  unit
(** Test seam for the best-effort invalidation failure path. Production
    callers should use {!invalidate_execution_cache}. *)

val patch_keeper_dependent_caches :
  keeper_name:string -> event:string -> unit
(** Applies in-place patches to every cached surface that
    depends on [keeper_name]'s status.  Maps SSOT
    lifecycle [event] names through the helpers below. *)

(** {1 Refresh fibers} *)

val start_execution_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  mono_clock:Eio.Time.Mono.ty Eio.Resource.t ->
  unit
(** Forks the per-process execution-cache refresh fiber.
    Idempotent.  Default refresh interval keeps timeout
    < interval (60 s) so [Proactive_refresh]'s clamp
    leaves room for the first build window after boot. *)

val start_transport_health_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** Forks the transport-health cache refresh fiber.
    Cheap compared to the execution refresh — a single
    snapshot at the current clock instant. *)

(** {1 Snapshot accessors} *)

val dashboard_execution_snapshot_json : unit -> Yojson.Safe.t
(** Returns the most recent successful execution
    snapshot (or the initialization placeholder when no
    refresh has succeeded yet). *)

val dashboard_transport_health_snapshot_json :
  unit -> Yojson.Safe.t
(** Returns the most recent transport-health snapshot. *)

(** {1 HTTP route entries} *)

val dashboard_execution_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** Implements the dashboard execution HTTP route.
    Reads through the per-request actor / fixture /
    light-mode query params, then routes via
    [Dashboard_cache.get_or_compute_with_timeout] with
    a 120 s TTL. *)

val dashboard_execution_trust_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** Renders the execution-trust dashboard surface
    (per-keeper rolled-up trust scores). *)

val dashboard_transport_health_http_json :
  state:Mcp_server.server_state -> Yojson.Safe.t
(** Returns the cached transport-health JSON with the
    cache-source diagnostic block extended.  Does not
    consume [sw] or [clock] — pure cache read. *)

(** {1 Lifecycle-event patchers}

    Mapping from SSOT keeper-lifecycle event names
    (e.g. [started] / [paused] / [resumed]) to the four
    cache-row fields the dashboard exposes.  Pinned at
    this boundary because [test/test_types] asserts
    every SSOT event has an entry in each map (#8396).
    [None] means "the event does not change this
    field". *)

val keepalive_running_of_lifecycle_event :
  string -> bool option

val phase_of_lifecycle_event : string -> string option

val pipeline_stage_of_lifecycle_event :
  string -> string option

val paused_of_lifecycle_event : string -> bool option

val seed_execution_cache_for_test : unit -> unit

val patch_surface_json_for_running_keepers :
  Coord.config -> Yojson.Safe.t -> Yojson.Safe.t

val patch_keeper_row :
  keeper_name:string ->
  event:string ->
  keepalive_running:bool ->
  Yojson.Safe.t ->
  Yojson.Safe.t
