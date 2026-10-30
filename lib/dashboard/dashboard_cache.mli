(** Dashboard response cache — time-bounded memoization with stale-while-revalidate.

    Per-key locking prevents deadlock from nested [get_or_compute] calls while
    still guarding against stampede (multiple fibers computing the same key).
    [compute] functions execute without holding the lock, so nested calls for
    different keys proceed without blocking.

    After a cached value expires, it is still served as stale data for
    [ttl * 3] additional seconds while a background fiber recomputes.
    This prevents slow endpoints from blocking HTTP responses.

    {b Runtime prerequisites}: callers must initialise [Time_compat.set_clock]
    and [Eio_context.set_switch] before using the cache. Background
    stale-while-revalidate fibers are registered on the root switch's owning
    domain and survive the requesting fiber or turn switch. Computation still
    uses the executor pool. *)

type payload_origin = Seeded | Computed | Timeout
(** The producer of this exact payload, independent of its JSON contents and
    of any later replacement in the cache. *)

type payload_preparation = Identity_only | Http_encodings
(** Representations prepared by the cache-fill worker. *)

type cached_payload = {
  json : Yojson.Safe.t;
  raw_json : string;
  etag : string;
  origin : payload_origin;
  encoded : Http_response_payload.prepared option;
}
(** Cached dashboard payload carrying the Yojson AST, pre-serialized JSON string,
    and weak entity tag. Payload computation prepares all three together before
    publication, so repeat requests do not serialize or hash again. *)

val get_or_compute :
  string -> ttl:float -> Yojson.Safe.t Pool_work.t -> Yojson.Safe.t
(** [get_or_compute key ~ttl work] returns a cached value if [key] exists and
    has not expired, otherwise runs [work] and stores the result for [ttl]
    seconds. [work] is submitted once, with the weight of the kind it declares
    ({!Pool_work.submit}); the cache chooses no weight of its own.

    If the entry is expired but within the stale grace period ([ttl * 3]),
    the stale value is returned immediately and [work] runs in a background
    fiber (requires [Eio_context.set_switch] to have been called).

    Safe to nest: [work] may call [get_or_compute] for a different key without
    deadlocking.  Concurrent requests for the same key are serialised — only
    one [work] runs; others wait for the result (stampede protection).
    JSON-only fills retain the AST without serializing or hashing it. *)

val get_or_compute_payload :
  ?preparation:payload_preparation ->
  string -> ttl:float -> Yojson.Safe.t Pool_work.t -> cached_payload
(** [get_or_compute_payload key ~ttl work] returns the {!cached_payload} for
    [key]. Runs [work] on cache miss, and memoizes both the JSON AST and the serialized
    string + ETag. With an executor pool installed, computation, serialization,
    and hashing share one worker submission on cold fills and background refresh,
    at the weight of [work]'s kind: an I/O work serializes and hashes at the
    I/O weight too. Cache hits with prepared bytes do not submit work.
    [Http_encodings] also prepares gzip/zstd inside that worker before publication.
    Preparation policy must be consistent for all producers of a cache key.
    Seeds and uncached timeout envelopes retain identity bytes only.
    A key first filled by a JSON-only reader retains that identity-only policy:
    its first payload reader prepares bytes once on the executor without rerunning
    [work]. Concurrent Eio readers share the preparation; raw native threads may
    encode concurrently, but every reader adopts the same published payload.
    JSON readers keep accessing the AST. Invalidation cannot republish the
    detached old value. *)

val select_http_representation :
  accept_encoding:string option -> cached_payload -> string * (string * string) list
(** Select already prepared bytes and headers without compression or allocation
    of response bodies. The payload ETag always identifies its identity bytes. *)

val peek : string -> Yojson.Safe.t option
(** [peek key] returns the currently cached value for [key] when a fresh or
    stale-ready entry exists. Unlike [get_or_compute], it never triggers a
    synchronous compute. Returns [None] on cache miss or when the key is
    currently computing without any stale fallback. *)

val peek_payload : string -> cached_payload option
(** [peek_payload key] returns already prepared bytes for a fresh or stale-ready
    entry. JSON-only entries return [None] until a payload reader prepares them.
    This never serializes, waits for preparation, or submits executor work. *)

(** Whose window closed when a compute timed out. *)
type compute_timeout_role =
  | Compute_owner (** the caller's own compute exceeded its window *)
  | Compute_waiter (** the caller was waiting on another fiber's compute *)

exception Compute_timeout of { key : string; role : compute_timeout_role }
(** Raised internally when the compute function exceeds [timeout_sec].
    Callers of [get_or_compute_with_timeout] do not need to handle this —
    it is caught and converted to a timeout-error JSON response. *)

val timeout_error_code : string
(** The [error] value carried by every timeout envelope this module emits. *)

(** Which wait ran out; the envelope reports it as [timeout_kind]. *)
type timeout_kind =
  | Timeout_owner (** the caller's own compute exceeded its window *)
  | Timeout_waiter (** the caller was waiting on another fiber's compute *)
  | Timeout_compute (** a computing slot yielded no result in time *)
  | Timeout_circuit_open (** repeated timeouts for the key: failing fast *)

val timeout_kind_of_role : compute_timeout_role -> timeout_kind
(** The kind an envelope reports for a {!Compute_timeout} with this role. *)

val timeout_envelope_json
  :  kind:timeout_kind
  -> key:string
  -> timeout_sec:float
  -> Yojson.Safe.t
(** The timeout envelope for [key]. Every producer builds it here, so the
    shape {!is_timeout_envelope} recognizes has one writer. *)

val is_timeout_envelope : Yojson.Safe.t -> bool
(** [is_timeout_envelope json] is [true] when [json] is a timeout envelope
    produced by this module rather than a computed payload.

    Readers must call this instead of matching the [error] string themselves:
    the recognizer shares {!timeout_error_code} with the producer, so the wire
    value cannot change under a reader. The envelope still travels in-band as
    data, which is why every reader needs this check at all; #28400 tracks
    moving it out of band and giving it its own HTTP status. *)

val get_or_compute_with_timeout :
  string -> ttl:float -> clock:_ Eio.Time.clock -> timeout_sec:float ->
  Yojson.Safe.t Pool_work.t -> Yojson.Safe.t
(** Like [get_or_compute] but runs the work under an Eio timeout.
    On timeout in the stale-while-revalidate path, the stale value is
    preserved (not overwritten by error JSON).  On timeout with no stale
    data, returns a timeout-error JSON without caching it.  Repeated no-stale
    timeouts for the same key open a short fail-fast circuit; fresh or stale
    cache entries are still served normally. *)

val get_or_compute_payload_with_timeout :
  ?preparation:payload_preparation ->
  string -> ttl:float -> clock:_ Eio.Time.clock -> timeout_sec:float ->
  Yojson.Safe.t Pool_work.t -> cached_payload
(** Same timeout and stale-value semantics as {!get_or_compute_with_timeout},
    retaining the memoized bytes and ETag of the returned JSON. Timeout envelopes
    are returned uncached. Preparation completes inside the timed worker compute
    before the cache entry is published. Prepared hits and stale responses do
    not wait for executor capacity. Preparing an existing JSON-only value also
    obeys [timeout_sec]; cancellation leaves the AST usable and permits a later
    payload reader to retry preparation. *)

val set_default_clock : _ Eio.Time.clock -> unit
(** Register the process clock so every {!get_or_compute} runs under the
    default backstop timeout. Called once at boot. Until it is called,
    [get_or_compute] keeps its original unbounded behaviour, which is what unit
    tests and non-Eio contexts rely on. A surface needing a tighter bound
    calls {!get_or_compute_with_timeout} with its own value. *)

val seed_stale_if_missing :
  string -> stale_for:float -> Yojson.Safe.t -> unit
(** [seed_stale_if_missing key ~stale_for value] inserts [value] as an
    immediately-stale entry only when [key] is absent. The next
    [get_or_compute] read returns [value] immediately and refreshes in the
    background when a switch is available. Existing entries are left intact.
    Seeds are intended for small warming responses: their bytes and ETag are
    prepared synchronously before publication, without using the executor pool.
    An existing slot skips preparation; a slot installed concurrently wins. *)

val seed_stale_from_if_missing : string -> from:string -> stale_for:float -> unit
(** [seed_stale_from_if_missing key ~from ~stale_for] puts [from]'s current
    value under [key] as an immediately-stale entry, only when [key] is absent
    and [from] still holds a value that may be served. The next read of [key]
    returns that value at once and computes [key] in the background, as for
    {!seed_stale_if_missing}. The value keeps [from]'s prepared bytes and
    entity tag. A key that names a version of its data (a generation) uses it
    so that the read after a write serves the previous version instead of
    computing the new one in the read (RFC-0474 L4d). *)

val invalidate : string -> unit
(** Remove a single cache entry.  If the key is currently being computed,
    waiting fibers are woken and will recompute. *)

val invalidate_prefix : string -> unit
(** Remove all cache entries whose key starts with the given prefix.  If any
    matching entry is currently being computed, waiting fibers are woken and
    will recompute. *)

val invalidate_all : unit -> unit
(** Remove all cache entries. Useful after mutations that change dashboard state. *)

val stats : unit -> Yojson.Safe.t
(** Returns [{"entries": N, "fresh": M, "stale": S, "computing": C, "expired": K}]
    for diagnostics. *)

module For_testing : sig
  val with_default_clock : _ Eio.Time.clock -> (unit -> 'a) -> 'a
  (** Install a default clock for this callback, restoring the prior option. *)

  val with_refresh_registered_hook : (unit -> unit) -> (unit -> 'a) -> 'a
  (** Pause after the root refresh is forked but before its registration is
      acknowledged to the reader. Process-wide; tests must not overlap other
      cache refreshes. The previous hook is restored on return or exception. *)

  val with_payload_prepared_hook :
    (cached_payload -> unit) -> (unit -> 'a) -> 'a
  (** Observe completed serialization before publication; restore the previous
      hook on return or exception. Tests using this process-wide hook must not
      overlap unrelated cache work. *)

  val compute_under_timeout :
    clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
    timeout_sec:float ->
    key:string ->
    (unit -> 'a) ->
    'a
  (** The window one cache compute runs under: a compute that finished as the
      window closed is the answer; the window raises [Compute_timeout] only
      when the compute has not finished. *)
end
