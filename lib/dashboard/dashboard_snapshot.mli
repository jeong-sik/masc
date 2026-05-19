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
  t
(** Test-only constructor.  Outside tests, snapshots are produced only
    by the refresh fiber. *)

val reset_for_test : unit -> unit
(** Test-only.  Clear the live slot back to [None]. *)
