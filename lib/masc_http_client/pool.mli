(** RFC-0107 Phase D Connection Pool.

    Design rationale lives in [docs/rfc/RFC-0107-phase-d-pool-design.md].
    Critical findings absorbed from Phase B Prior Art research
    ([knowledge/research/2026-05-17-piaf-ocsigen-eio-fd-prior-art.md]):

    - piaf's [Client.t] is per-endpoint, not multi-host. We build the
      [Host_key -> piaf Client.t queue] layer ourselves on top.
    - cohttp upstream patch is not viable (issue #85 closed 2014, eio
      not covered). piaf is the only rational transport choice.
    - Eio #244 "exactly-one-owner" principle motivates the no-double-
      release invariant enforced by the scoped [request] API (no naked
      acquire / release exposed). *)

(** Opaque per-process connection pool. Attaches to a long-lived
    [Eio.Switch] (typically server root_sw via [Eio_context]). The pool
    survives turn boundaries; per-host connection state evicts on
    [idle_ttl]. *)
type t

(** Pool tuning parameters. Conservative defaults derived from
    RFC-0101 §2 nofile cap (10240).

    [max_idle_per_host]: bound on idle (reusable) connections kept per
    {scheme, host, port} tuple after a request completes.

    [max_total_idle]: bound on idle connections across all hosts. When
    exceeded, the LRU host's oldest idle connection is evicted before
    a new one is parked.

    [idle_ttl_seconds]: idle connection's max age before eviction. A
    pool fiber walks idle queues periodically; expired entries are
    closed and dropped.

    [connect_timeout_seconds]: max wait when establishing a fresh
    connection. Surfaces as [Error "connect timeout ..."] to the
    caller. *)
type config = {
  max_idle_per_host : int;
  max_total_idle    : int;
  idle_ttl_seconds  : float;
  connect_timeout_seconds : float;
}

val default_config : config
(** [{ max_idle_per_host = 8; max_total_idle = 256;
       idle_ttl_seconds = 60.0; connect_timeout_seconds = 5.0 }]. *)

val create :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  ?config:config ->
  unit ->
  t
(** Initialize the pool on a long-lived switch (server root_sw). Idle
    connections close when [sw] closes; in-flight requests outlive
    pool cleanup via per-call sub-switches.

    [env] is the full Eio standard environment, required by the piaf
    transport (h1/h2 client creation). The pool keeps a reference and
    issues [Piaf.Client.create ~sw env uri] internally on cache miss. *)

(* ── Request API ───────────────────────────────────────────────── *)

(** Typed HTTP response. Mirrors [Masc_http_client] response shape so
    the migration shim is a one-line wrap. *)
type response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

type http_method = [ `GET | `POST | `PUT | `DELETE | `HEAD | `PATCH ]

val request :
  t ->
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_seconds:float ->
  method_:http_method ->
  url:string ->
  ?headers:(string * string) list ->
  ?body:string ->
  unit ->
  (response, string) result
(** Scoped one-shot request. Acquires a connection from the per-host
    pool (or creates one if the pool is empty / under
    [max_idle_per_host]), issues the request, releases the connection
    back to the pool for keep-alive reuse, and returns the typed
    response.

    Failure modes (all return [Error]):
    - DNS / TCP / TLS failure during connect
    - HTTP read error during reuse (pool drops the bad connection)
    - timeout when [clock] and [timeout_seconds] are both provided

    Notably absent: silent retry. If a reused connection fails, the
    caller sees [Error] with the underlying reason. Caller decides
    whether to retry — N-of-M silent retry is an
    RFC-0107 §"Workaround Rejection Bar" anti-pattern. *)

(** {2 RFC-0129 — idle-timeout request with streaming progress}

    Replaces the wall-clock total-timeout pattern used by [request].
    Chunk arrival on the response body resets the idle timer; a stream
    that keeps delivering bytes is never cancelled, regardless of total
    elapsed time. A stream that stops producing bytes for longer than
    [idle_timeout_sec] is cancelled.

    Progress fields are returned on both the [Ok] and [Error] branches
    so runtime rotation receipts can attach them without a side-channel.

    Design rationale: docs/rfc/RFC-0129-http-idle-timeout-and-streaming-progress.md *)

(** Body streaming progress observed during a single request. All
    timestamps are seconds since request start (monotonic). *)
type body_progress = {
  first_byte_at_sec : float option;
  last_chunk_at_sec : float option;
  bytes_received    : int;
}

val empty_body_progress : body_progress

val request_with_idle_timeout :
  t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  idle_timeout_sec:float ->
  ?total_timeout_sec:float ->
  method_:http_method ->
  url:string ->
  ?headers:(string * string) list ->
  ?body:string ->
  unit ->
  (response * body_progress, string * body_progress) result
(** Issue a request with body-idle cancellation. Chunk delivery resets
    the idle timer; absence of bytes for [idle_timeout_sec] cancels the
    fiber. [total_timeout_sec] is an optional hard cap that bounds the
    request regardless of streaming activity (default: no hard cap;
    keeper turn budget bounds the outer loop).

    Progress is observed even on failure. Error string carries one of:
    - ["idle timeout after %.1fs"]      (body silent past idle_timeout_sec)
    - ["total timeout after %.1fs"]     (total_timeout_sec elapsed)
    - any Piaf error message. *)

(* ── Telemetry ─────────────────────────────────────────────────── *)

(** Non-mutating pool snapshot for Otel_metric_store / dashboard. Phase D.4
    wires this to the metrics layer. *)
type stats = {
  idle_per_host : (string * int) list;
  total_idle : int;
  total_inflight : int;
  reuse_count_total : int;
  evict_count_total : int;
  (** Increments when the periodic eviction fiber catches an
      exception while sweeping idle entries. Operator-visible signal
      that the pool's TTL cleanup is silently failing. Surfaced as
      [masc_pool_evict_failure_total] in Otel_metric_store. *)
  evict_failure_count_total : int;
  create_count_total : int;
}

val stats : t -> stats

(** {1 Test-only — internal data structures}

    Exposed for unit testing of the pure pieces (Host_key normalization,
    config defaults) without requiring piaf integration. Do not call
    from production code. *)
module For_testing : sig
  module Host_key : sig
    type t = {
      scheme : string;
      host   : string;
      port   : int;
    }
    val of_uri : Uri.t -> t
    val to_string : t -> string
    val compare : t -> t -> int
  end

  (** Exposed for cleanup contract tests: close an unreleased client exactly
      once in a cancel-protected finalizer and swallow release exceptions so
      [Fun.protect] does not mask the original request/body exception. *)
  val close_unreleased_client :
    bool ref -> (close_only:bool -> unit) -> unit

  (** Exposed so unit tests can drive idle-timeout logic against a
      mock [Piaf.Body.t] built from [Piaf_stream.create], without
      standing up a real HTTP server. *)
  val read_body_with_idle :
    ?progress_ref:body_progress ref ->
    clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
    start_sec:float ->
    idle_timeout_sec:float ->
    Piaf.Body.t ->
    (string * body_progress, string * body_progress) result
end
