(** Lock-free immutable dashboard snapshot, published by a single
    background fiber and read by HTTP handlers without blocking.

    See RFC-0138 ([docs/rfc/RFC-0138-dashboard-snapshot-lock-free-architecture.md])
    for the motivation, migration sequence, and acceptance criteria.

    The contract enforced by this module:

    - {!current} is wait-free.  It must {b never} block, allocate
      unboundedly, or raise.  HTTP handlers may call it on the request
      fiber.
    - {!t} values are immutable.  A field obtained from {!current} stays
      valid for the lifetime of the caller's reference; subsequent
      publishes do not mutate it.
    - {!refresh_loop} is the {b only} site that computes a fresh
      snapshot.  Direct calls to {!Server_dashboard_http_core},
      {!Telemetry_unified} for read traffic must migrate to read from
      {!current_or_bootstrap}.

    OCaml 5 [Atomic] holds an immutable record reference; readers see a
    consistent snapshot per call (no torn reads). *)

type t = private {
  generated_at : float;          (** Unix.gettimeofday at publish.  *)
  generation : int;              (** Monotonic publish counter.    *)
  shell : Yojson.Safe.t;
  tools : Yojson.Safe.t;
  namespace_truth : Yojson.Safe.t;
  telemetry_summary : Yojson.Safe.t;
  activity_events_default : Yojson.Safe.t;
  (** RFC-0201 Step 1.  [Activity_graph.json_response] computed against
      the default-shaped query ([kinds=[]], [after_seq=0],
      [limit=1000]).  Handlers slice this to the request's [limit] for
      default-shaped queries; non-default queries (cursor, kinds
      filter, since) fall through to the synchronous compute path.
      [`Null] until the refresh fiber's first publish (bootstrap stays
      [`Null] like [namespace_truth]). *)
  activity_graph_default : Yojson.Safe.t;
  (** RFC-0201 Step 2.  [Activity_graph.graph_json] computed against
      the dashboard panel's default query ([kinds=[]], [limit=500],
      [timeline_limit=80], [since_ms=None]).  Returned as-is to
      default-shape callers — the result is aggregated (heatmap +
      timeline + series counts) and cannot be sliced post-compute.
      Non-default queries (kinds filter, alternate [limit] /
      [timeline_limit], [since]) fall through to the synchronous
      compute path.  [`Null] before first refresh-fiber publish. *)
  activity_swimlane_default : Yojson.Safe.t;
  (** RFC-0201 Step 3.  [Activity_graph.agent_spans_json] computed
      against the dashboard panel's default query ([limit=500],
      [since_ms=None]).  Same as-is return contract as
      [activity_graph_default]. *)
}

val current : unit -> t option
(** [Atomic.get] from the live slot.  Returns [None] until the first
    successful publish.  Wait-free; total. *)

val current_or_bootstrap : config:Coord.config -> t
(** [current ()] if populated; otherwise a single bootstrap value
    computed synchronously on the calling fiber.  The bootstrap path is
    taken at most once per process lifetime (first request before the
    refresh loop has emitted). *)

val refresh_loop :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  config:Coord.config ->
  ?state:Mcp_server.server_state ->
  interval_sec:float ->
  unit ->
  unit
(** Run forever in the given switch.  Every [interval_sec] seconds,
    recompute a fresh {!t} and publish via [Atomic.set].  If a refresh
    raises, the {b previous} snapshot stays live (no torn state) and
    the error is logged.  Cancellation via the switch propagates
    cleanly through {!Eio.Time.sleep}.

    [?state] (RFC-0138 Phase 3 Step 3) — when supplied, the refresh
    loop additionally populates the snapshot's [namespace_truth] via
    [Server_dashboard_http_namespace_truth.namespace_truth_snapshot_from_caches].
    That function reads cached refs only (no PG I/O, no fiber
    timeouts), so it is safe to call from a background fiber.  When
    [?state] is omitted, [namespace_truth] stays [`Null] in published
    snapshots — handlers fall back to the synchronous request-fiber
    path. *)

val publish_for_test : t -> unit
(** Test-only injection.  No production caller may use this. *)

val make_for_test :
  shell:Yojson.Safe.t ->
  tools:Yojson.Safe.t ->
  namespace_truth:Yojson.Safe.t ->
  telemetry_summary:Yojson.Safe.t ->
  ?activity_events_default:Yojson.Safe.t ->
  ?activity_graph_default:Yojson.Safe.t ->
  ?activity_swimlane_default:Yojson.Safe.t ->
  unit ->
  t
(** Test-only constructor.  Outside tests, snapshots are produced only
    by the refresh fiber. *)

val reset_for_test : unit -> unit
(** Test-only.  Clear the live slot back to [None]. *)
