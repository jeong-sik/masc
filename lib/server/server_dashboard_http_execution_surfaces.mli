(** Cached execution, execution-trust and transport observations.

    Execution retains one publication owner per workspace scope. Its cache,
    attempt order, semantic deadline and prepared response bytes retire
    together. Original input changes and actual HTTP/cache completions use
    separate typed paths, so canonical output never re-enters the source
    worker. The process publication epoch shared with Goal response headers
    stays stable; publication generations advance across scope replacement.
    HTTP and canonical SSE carry [observer_instance_id] only from the captured
    scope. An isolated test owner has no observer authority to attest. *)

(** {1 Cache cells} *)

type cached_surface = Server_dashboard_http_cache.cached_surface

type execution_http_response =
  | Execution_json of Yojson.Safe.t
  | Execution_payload of Dashboard_cache.cached_payload

val execution_publication_epoch : string
(** Process-scoped identity of the execution publication stream. *)

val execution_cache : state:Mcp_server.server_state -> cached_surface
(** Cached execution surface JSON.  Reached by
    [Server_dashboard_http_namespace_truth] (via the
    [Execution_surfaces] alias) for readiness gating —
    the namespace-truth refresh skips the live execution
    fetch when this cache is still serving a successful
    snapshot. Each workspace scope owns a separate publication cell, ticket
    order and prepared HTTP body. A retired request cannot replace another
    scope's last-good answer, including a same-path replacement. *)

val execution_cache_for_scope :
  state:Mcp_server.server_state -> Mcp_server.workspace_scope -> cached_surface
(** Retain the cache for an already captured scope. A delayed retired lookup
    receives a private cell and cannot retire the current scope's owner. *)

val execution_cached_observation_for_scope :
  state:Mcp_server.server_state -> Mcp_server.workspace_scope ->
  Server_dashboard_http_cache.surface_snapshot * Dashboard_projection_read.completeness option
(** Capture one immutable cache source and its typed read outcome under the
    same owner lock. [None] means no admitted observation/error in the current
    hard generation; it must not become a complete namespace observation.
    Actual failure with no body is [Partial] for canonical error reporting,
    while default Execution GET still distinguishes it from retained rows.
    An explicit canonical cache success marker is also complete; ordinary
    invalidation clears both success and error markers. *)

val last_good_shell_for_scope :
  state:Mcp_server.server_state -> Mcp_server.workspace_scope -> Yojson.Safe.t option

val namespace_cache_revision :
  state:Mcp_server.server_state -> Mcp_server.workspace_scope -> int
(** Successful execution/Shell installations and lifecycle patches advance the
    canonical completion revision, including an equal-valued light Shell.
    This is completion identity, not Task or Goal authority. *)

val publish_shell_cache_success :
  state:Mcp_server.server_state -> scope:Mcp_server.workspace_scope ->
  light:bool -> Yojson.Safe.t -> unit
(** Install this scope's successful shell and enqueue canonical namespace
    completion after the cache update. Late retired completions are ignored;
    fanout never runs inline inside this cache installation. *)

val execution_trust_cache : state:Mcp_server.server_state -> cached_surface
(** Cached execution-trust surface JSON.  The default
    [/api/v1/dashboard/execution-trust] route serves this last-good
    surface after the first successful compute. Each workspace scope gets a
    separate cell; a retired read cannot replace the current scope's answer.
    Original inputs and receipt-freshness deadlines keep it current. *)

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
    supplied full-health snapshot invalidator. Health is invalidated after the
    execution caches and before the execution SSE broadcast. Server bootstrap
    installs the callback before Workspace mutation hooks become available. *)

module For_testing : sig
  type owner
  type origin = Observation_read | Request_read
  type completion =
    | Cache_installed of origin
    | Cache_failed of origin
    | Cache_patched
    | Shell_installed
  val create_owner : unit -> owner
  val owner_for_state : state:Mcp_server.server_state -> owner
  val cache : owner -> cached_surface
  val invalidate : owner -> unit
  (** An isolated publication owner for the cache/attempt boundary fixtures. *)
  val subscribe_completion : owner:owner -> (completion -> unit) -> (unit -> unit)
  (** The production after-cache completion subscription. Fixture callbacks
      follow the same non-I/O contract and may resolve a promise only. *)

  val execution_publication_generation : owner:owner -> unit -> int

  val publish_execution_success_if_current :
    owner:owner -> generation:int -> Yojson.Safe.t -> bool
  (** Publishes as an attempt that began after every attempt so far: [false]
      only when the surface was invalidated since [generation]. An attempt
      still running then publishes nothing. *)

  type execution_attempt
  (** One attempt at publishing the execution surface: the generation it began
      under and its place in the order of attempts. Attempts that run at once
      share a generation; the one that began later is the newer, and the
      outcome of an older attempt is not published over a newer attempt's. *)

  val begin_execution_attempt : owner:owner -> unit -> execution_attempt

  val publish_execution_attempt_success : execution_attempt -> Yojson.Safe.t -> bool
  (** [false] when the surface was invalidated since the attempt began, or a
      newer attempt has already published. *)

  val publish_execution_observation : execution_attempt -> Dashboard_execution.observation -> bool
  (** Actual rich read admission. Partial preserves its readable rows and
      diagnostics without stamping complete success; hard generation, ordered
      attempt and workspace retirement fences apply to both outcomes. *)

  val publish_execution_attempt_failure : execution_attempt -> exn -> bool
  (** Publishes [exn] unless the surface was invalidated since the attempt
      began, this attempt has already published an answer, or a newer attempt
      has published anything. What an attempt does after publishing --
      refreshing the light body, and the window around the whole attempt --
      must not replace the answer this attempt already recorded, and the
      outcome of an older read must not replace a newer one. *)

  val publish_execution_attempt_failure_message : execution_attempt -> string -> bool
  (** The same admission as {!publish_execution_attempt_failure}, for a failure
      that is known only by its message. The refresh loop publishes the
      attempt's [exn] from the attempt, then its window's message from
      [on_failure], both under one attempt. *)

  val cached_response :
    ?observe:(config:Workspace.config -> Yojson.Safe.t -> Yojson.Safe.t) ->
    owner:owner ->
    config:Workspace.config -> Httpun.Request.t ->
    execution_http_response option

  val refresh_execution_default_light_http_body :
    ?prepare:(string -> Http_response_payload.prepared) ->
    owner:owner ->
    config:Workspace.config -> unit -> Yojson.Safe.t
  (** The preparation callback runs outside the publication lock on the CPU
      worker. It can coordinate source changes and concurrent readers. *)

  val prepare_execution_snapshot_broadcast :
    owner:owner -> config:Workspace.config -> unit -> Yojson.Safe.t
  (** Production SSE payload preparation, including current ledger observations. *)

  val prepared_payload_for_snapshot :
    owner:owner -> config:Workspace.config -> Server_dashboard_http_cache.surface_snapshot ->
    Dashboard_cache.cached_payload option
  (** Returns bytes only for this exact, still-current successful snapshot and
      workspace. Used to exercise invalidation during cold response preparation. *)
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
(** Install the scope-bound execution observer and canonical completion
    publisher. Initial read, original affecting inputs and returned semantic
    deadlines own the debt. Successful idle has no refresh timer. HTTP cold
    and force fills use the same publication owner and announce completion;
    an older worker can never rebroadcast its superseded computed answer. *)

val start_transport_health_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** Subscribe before an initial transport sample, then refresh only on actual
    transport lifecycle or validated original publication input. A successful
    quiet surface has no interval. Observation delivery/cost mirrors are
    measured at the next actual sample or manual read, avoiding self fanout. *)

val start_execution_trust_refresh_loop :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  unit
(** Fork the scope-bound execution-trust observer. A healthy read settles
    until an affecting original input or its exact receipt-freshness deadline.
    The existing timeout and failure retry policy remain. *)

(** {1 HTTP route entries} *)

type execution_http_request
(** Immutable, request-local actor/query resolution tied to its server state
    and workspace. Created after HTTP admission and shared by the prepared
    response lookup and fallback path; never cached across requests. *)

val execution_http_request :
  state:Mcp_server.server_state -> Httpun.Request.t -> execution_http_request

val dashboard_execution_cached_http_response :
  execution_http_request ->
  execution_http_response option
(** Observe current Keeper addresses and Candle state against a prepared
    default snapshot. Unchanged observations retain its prepared payload;
    changed observations return their fresh JSON directly, without discarding
    it and repeating the reads in the fallback path. Neither case serializes
    or compresses here. [None] means actor, fixture, full, force, initializing,
    stale/error, or publication changed during observation. Source identity
    and publication validity are checked again after the yielding observation. *)

val dashboard_execution_http_response :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  execution_http_request ->
  execution_http_response
(** Parameterized requests retain the decorated snapshot's bytes and ETag in
    the SWR cache, scoped by workspace, query and publication generation.
    A non-forced default light read also reuses the bytes it just prepared when
    they still belong to its selected successful snapshot and workspace.
    Invalidated/superseded reads, forced refreshes and cache-generated timeout
    envelopes retain their JSON response. *)

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

val seed_execution_cache_for_test : state:Mcp_server.server_state -> unit -> unit

val patch_surface_json_for_running_keepers :
  Workspace.config -> Yojson.Safe.t -> Yojson.Safe.t

(** What a lifecycle event does to a published keeper list. A declaration row
    ({!Keeper_declared_roster.row_kind_of_json}) is a Keeper the snapshot saw
    before it ever booted. It has no diagnostic or trust to become a runtime
    row from, so it is never patched: the surface holding it is stale. The
    lifecycle patch of the cached execution surface then invalidates it; the
    running-keeper reconciliation of a fresh render
    ({!patch_surface_json_for_running_keepers}) leaves the row as its snapshot
    described it. *)
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
    [Invalid_argument] for [keeper_name]'s row when its [declaration_only] is
    not a boolean, and for its runtime row when [keepalive_running] is [true],
    [event] sets no status of its own, and the row's current status is missing
    or not a control-plane status. *)

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
(** Publish a digest through the shared snapshot serializer. The source-driven
    Digest worker publishes directly to its captured workspace/instance. *)
