(** Token bucket per LLM provider, modeling provider-side rate limits.

    Part of the keeper-liveness architecture (see RFC: keeper provider
    scheduling). This module owns the rate-respect invariant:

      I3 (Rate-respect): for each provider [p] and time window [W],
                         dispatched(p, W) <= rate_limit(p) * |W|

    Non-blocking primitive: [try_acquire] returns immediately with a bool.
    The scheduler (separate module, future PR) is responsible for picking
    the next candidate provider when a bucket is empty — a single bucket
    must never block a fiber, otherwise per-keeper liveness can fail.

    Cross-fiber safe: protected by a [Stdlib.Mutex] internally. Critical
    section is microseconds (lazy refill arithmetic + small field updates),
    so blocking the carrier thread is acceptable inside an Eio context. *)

type provider_id = string
(** Opaque label, e.g. ["anthropic"], ["codex_cli"], ["glm"]. The string is
    only used as a tag — the bucket itself does not interpret it. *)

type t

val create :
  provider:provider_id ->
  capacity:int ->
  refill_rate:float ->
  now:(unit -> float) ->
  t
(** [create ~provider ~capacity ~refill_rate ~now] builds a fresh bucket.

    - [capacity]: maximum burst size (tokens). Bucket starts full.
    - [refill_rate]: tokens added per second. Must be [> 0.0].
    - [now]: clock injection. In production pass [Unix.gettimeofday];
      in tests pass a controlled clock so refill behaviour is deterministic.

    Raises [Invalid_argument] if [capacity < 1] or [refill_rate <= 0.0]. *)

val try_acquire : t -> bool
(** Attempt to consume one token. Returns [true] on success.

    Performs a lazy refill based on elapsed time since the last access,
    then checks for [>= 1.0] tokens. Always non-blocking. *)

val tokens_available : t -> float
(** Current token count after a fresh refill. For observability and tests.
    Calling this performs the same lazy-refill side effect as [try_acquire]
    (mutating [last_refill_at]) but does not consume a token. *)

val provider : t -> provider_id
(** The provider tag passed to [create]. *)

val release : t -> unit
(** Return one token to the bucket.  Non-blocking; clamps at capacity.
    Callers MUST pair every [try_acquire] that returned [true] with
    exactly one [release] when the work completes. *)

type refill_callback = unit -> unit

val add_on_refill : t -> refill_callback -> unit
(** Register a callback to be invoked when a refill event moves the
    bucket from [< 1.0] to [>= 1.0] tokens.  This signals that a
    previously throttled provider now has dispatchable capacity.
    Multiple callbacks are supported (LIFO order).  Thread-safe. *)

val refilled :
  current_tokens:float ->
  capacity:int ->
  refill_rate:float ->
  elapsed_sec:float ->
  float
(** Pure function: compute the new token count after [elapsed_sec] elapse.
    Capped at [capacity], floored at [current_tokens] when [elapsed_sec < 0]
    (clock skew defence). Exposed for unit tests of the refill arithmetic
    in isolation from mutex/state. *)
