(** Server_dashboard_http_execution_surfaces — cached
    execution + transport-health dashboard surfaces.

    [Server_dashboard_http] does
    [include Server_dashboard_http_execution_surfaces];
    [server_dashboard_http_namespace_truth.ml] does
    [module Execution_surfaces = ...] alias and reaches
    {!execution_cache} +
    {!broadcast_namespace_truth_ref} through it.  Plus
    direct dotted callers.  A [let module S = ...] inline alias for
    the lifecycle-event patcher family was cited in
    [test/test_types.ml], which does not exist.

    External surface (22 entries):
    - {b cache cells} ({!execution_cache},
      {!broadcast_namespace_truth_ref}) reached by
      [server_dashboard_http_namespace_truth] for
      readiness gating + truth-broadcast wiring, plus
      {!execution_trust_cache} for the execution-receipt
      trust read model.
    - {b shell prewarm} ({!warm_shell_cache}) — called
      at server bootstrap.
    - {b dashboard actor resolution}
      ({!execution_actor_for_request}).
    - {b cache management}
      ({!invalidate_execution_cache},
      {!patch_keeper_dependent_caches}).
    - {b refresh fibers}
      ({!start_execution_refresh_loop},
      {!start_transport_health_refresh_loop},
      {!start_execution_trust_refresh_loop}).
    - {b snapshot access} ({!dashboard_execution_snapshot_json}).
    - {b HTTP route entries}
      ({!dashboard_execution_cached_http_representation},
      {!dashboard_execution_http_json},
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
    - {b SSE-event row patchers}
      ({!patch_keeper_row},
      {!patch_surface_json_for_running_keepers}) —
      pinned because [test/test_dashboard_execution]
      tests their null-agent-shape tolerance directly
      (test_patch_keeper_row_tolerates_null_agent_shape /
      test_patch_surface_json_for_running_keepers_tolerates_null_agent).

    Internal helpers stay private at this boundary
    ([shell_prewarm_timeout_s],
    [last_broadcast_payload] /
    [broadcast_payload_mu] / [broadcast_cached_surface] /
    [operator_snapshot_publication_is_current] / [operator_snapshot_json] /
    [broadcast_current_successful_operator_snapshot],
    [_transport_health_cache],
    [keeper_top_level_status_opt] / [patched_keeper_status],
    [patch_runtime_row] / [patch_keeper_rows] SSE-event row patcher helpers,
    [running_keeper_names],
    [patchexecution_cache_for_keeper],
    [transport_health_cache_diagnostics]). *)

(** {1 Cache cells} *)

type cached_surface = Server_dashboard_http_cache.cached_surface

val execution_cache : cached_surface
(** Cached execution surface JSON.  Reached by
    [Server_dashboard_http_namespace_truth] (via the
    [Execution_surfaces] alias) for readiness gating —
    the namespace-truth refresh skips the live execution
    fetch when this cache is still serving a successful
    snapshot. *)

val execution_trust_cache : cached_surface
(** Cached execution-trust surface JSON.  The default
    [/api/v1/dashboard/execution-trust] route serves this last-good
    surface after the first successful compute; the proactive refresh
    loop keeps it current without making every dashboard poll pay the
    receipt projection cost. *)

val broadcast_namespace_truth_ref :
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
    snapshot read recomputes from upstream. Runs the cache/tombstone
    settlement cancellation-protected and logs/counts projection failures
    through
    {!Keeper_metrics.(to_string LifecycleCallbackFailures)}. *)

val install_task_mutation_cache_invalidation :
  invalidate_full_health_snapshot:(unit -> unit) -> unit -> unit
(** Connects task mutation commits to {!invalidate_execution_cache} and the
    supplied full-health snapshot invalidator. Server bootstrap installs the
    composed callback before Workspace mutation hooks become available. *)

module For_testing : sig
  val execution_publication_generation : unit -> int

  val publish_execution_success_if_current :
    generation:int -> Yojson.Safe.t -> bool

  type execution_attempt
  (** One forced-refresh attempt at publishing the execution surface: the
      generation it began under, and whether it published an answer. *)

  val begin_execution_attempt : unit -> execution_attempt

  val publish_execution_attempt_success : execution_attempt -> Yojson.Safe.t -> bool

  val publish_execution_attempt_failure : execution_attempt -> exn -> bool
  (** Publishes [exn] only while this attempt has published no answer. What an
      attempt does after publishing -- refreshing the light body, and the
      window around the whole attempt -- must not replace the answer this
      attempt already recorded. Another attempt on the same generation is a
      different attempt and is not covered by this; see the concurrent-force
      note in the implementation. *)

  val cached_representation :
    config:Workspace.config -> Httpun.Request.t ->
    (string * string * (string * string) list) option

  val refresh_execution_default_light_http_body :
    ?prepare:(string -> Http_response_payload.prepared) ->
    config:Workspace.config -> unit -> Yojson.Safe.t
  (** The preparation callback runs outside the publication lock on the CPU
      worker. It can coordinate source changes and concurrent readers. *)
end

val patch_keeper_dependent_caches :
  keeper_name:string ->
  event:Keeper_lifecycle_events.lifecycle_event ->
  unit
(** Applies the lifecycle delta to the execution cache and its serialized
    default body. Operator snapshots are never patched in place; their mutation
    paths advance the projection generation and publish a canonical tombstone.
    Maps SSOT lifecycle [event] names through the helpers below. *)

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
    leaves workspace for the first build window after boot. *)

val start_transport_health_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** Forks the transport-health cache refresh fiber.
    Cheap compared to the execution refresh — a single
    snapshot at the current clock instant. *)

val start_execution_trust_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** Forks the execution-trust cache refresh fiber.
    Uses the existing dashboard execution-trust timeout and the shared
    proactive-refresh circuit breaker; no additional operator env knob
    is introduced for the interval. *)

(** {1 Snapshot accessors} *)

(** {1 HTTP route entries} *)

type execution_http_request
(** Immutable, request-local actor/query resolution tied to its server state
    and workspace. Created after HTTP admission and shared by the prepared
    response lookup and fallback path; never cached across requests. *)

val execution_http_request :
  state:Mcp_server.server_state -> Httpun.Request.t -> execution_http_request

val dashboard_execution_cached_http_representation :
  execution_http_request ->
  (string * string * (string * string) list) option
(** Negotiated pre-compressed body, weak ETag of the identity JSON, and
    representation headers. Returns [None] for actor, fixture, full, force,
    initializing or stale/error requests. No serialization or compression on
    cache hits. *)

type execution_http_response =
  | Execution_json of Yojson.Safe.t
  | Execution_payload of Dashboard_cache.cached_payload

val dashboard_execution_http_response :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  execution_http_request ->
  execution_http_response
(** Parameterized requests retain the decorated snapshot's bytes and ETag in
    the SWR cache, scoped by workspace, query and publication generation.
    Default light reads (including forced refresh) and cache-generated timeout
    envelopes return JSON. *)

val dashboard_execution_http_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Httpun.Request.t ->
  Yojson.Safe.t
(** Implements the dashboard execution HTTP route.
    Reads through the per-request actor / fixture /
    light-mode / force query params, then routes via
    [Dashboard_cache.get_or_compute_with_timeout] with
    a 120 s TTL.  Default light [force=true] bypasses the
    default execution cache once and updates it on success. *)

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
    consume [sw] or [clock] — pure cache read.

    Not to be wrapped in a route-level cache. It reads a published cell and
    derives [cache_state], [stale_reason] and [stale_age_ms] from it against
    the clock. A cache in front holds the answer to a question about
    freshness: the route did that for 30s and served the previous "fresh"
    payload after the surface had gone to an error state, with
    [stale_age_ms] frozen so the age stood still while the surface aged
    (#27652). *)

(** {1 Lifecycle-event patchers}

    Mapping from typed SSOT keeper-lifecycle transitions
    to the four cache-row fields the dashboard exposes.
    [None] means "the transition does not change this
    field". *)

val keepalive_running_of_lifecycle_event :
  Keeper_lifecycle_events.lifecycle_event -> bool option

val phase_of_lifecycle_event :
  Keeper_lifecycle_events.lifecycle_event -> string option

val pipeline_stage_of_lifecycle_event :
  Keeper_lifecycle_events.lifecycle_event -> string option

val paused_of_lifecycle_event :
  Keeper_lifecycle_events.lifecycle_event -> bool option

val seed_execution_cache_for_test : unit -> unit

val patch_surface_json_for_running_keepers :
  Workspace.config -> Yojson.Safe.t -> Yojson.Safe.t

(** What a lifecycle event does to a published keeper list. A declaration row
    ({!Keeper_declared_roster.row_kind_of_json}) is a Keeper the snapshot saw
    before it ever booted. It has no diagnostic or trust to become a runtime
    row from, so it is never patched: the surface holding it is stale. The
    execution cache then invalidates itself so the next read recomputes from a
    fresh snapshot. *)
type 'rows row_patch =
  | Patched of 'rows
  | Declaration_row_is_stale

val patch_keeper_row :
  keeper_name:string ->
  event:Keeper_lifecycle_events.lifecycle_event ->
  keepalive_running:bool ->
  Yojson.Safe.t ->
  Yojson.Safe.t row_patch
(** A row that is not [keeper_name]'s comes back [Patched] unchanged. Raises
    [Invalid_argument] for [keeper_name]'s runtime row when its status is
    missing or unknown, or when its [declaration_only] is not a boolean. *)

val broadcast_operator_snapshot :
  Server_dashboard_http_core_operator.operator_snapshot_publication -> unit
(** Publish an operator snapshot on SSE, if the publication still matches the
    current one. The payload is encoded on the calling fiber without yielding,
    so a caller holding a lock may use it: the /api/v1/operator route and the
    invalidation observer do. *)

val broadcast_refreshed_operator_snapshot :
  Server_dashboard_http_core_operator.operator_snapshot_publication -> unit
(** {!broadcast_operator_snapshot} with the payload encoded on the domain pool,
    for a caller that holds nothing and may yield. Passed to the snapshot
    refresh loop at boot. A publication replaced while it encodes is not
    broadcast; the current one is when it is a success, since a success the
    route published has no broadcaster of its own. *)

val broadcast_operator_digest : Yojson.Safe.t -> unit
(** Publish an operator digest on SSE. Passed to the digest refresh loop at
    boot.

    Both used to reach their loops through process-global [Atomic.t] cells that
    module initializers here filled, because
    [Server_dashboard_http_core_operator] is compiled before [Sse] is in scope
    here and cannot name these bodies. The cells defaulted to functions that
    did nothing, so a missing registration was a broadcast that silently went
    nowhere (#25927). *)
