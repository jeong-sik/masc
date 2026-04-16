(** Per-cascade-name in-memory state container for stateful strategies.

    Phase A strategies (Failover/Capacity_aware/Weighted_random/
    Circuit_breaker_cycling) are pure — they read [signal_ctx] and
    return an ordering.  Phase B introduces three strategies that
    require external state across calls:

    - [Sticky] remembers each [(keeper, cascade)]'s last successful
      provider for [sticky_ttl_ms] so subsequent attempts pin to the
      same backend (warm caches, session affinity).
    - [Round_robin] maintains a per-cascade rotation cursor so
      successive cascade calls start from a different candidate,
      spreading load.
    - [Priority_tier] is stateless (tier table comes from config) and
      does not touch this module.

    All entries live in process-local Hashtbls.  Restart resets
    everything — Phase B is in-memory only.  Persistence to
    [<base_path>/.masc/cascade_state.json] is deferred to a future
    PR; the API here is intentionally side-effect-only so a
    persistence layer can be slotted in without changing callers.

    Concurrency: every operation uses [Atomic.t] or short critical
    sections under [Eio.Mutex.t].  Safe to call from multiple Eio
    fibers and (for Atomic-only ops) from multiple OCaml domains.

    @since 0.9.7 *)

(** {1 Sticky state} *)

val record_sticky_choice :
  keeper:string ->
  cascade:string ->
  provider:string ->
  ttl_ms:int ->
  now:float ->
  unit
(** Record a successful provider for [(keeper, cascade)].  Overwrites
    any existing entry.  [now] is the wall-clock time used to compute
    [expires_at = now + ttl_ms / 1000].  No effect when [ttl_ms <= 0]
    (TTL disabled). *)

val lookup_sticky :
  keeper:string ->
  cascade:string ->
  now:float ->
  string option
(** [lookup_sticky ~keeper ~cascade ~now] returns the recorded provider
    when an entry exists and [now < expires_at]; [None] otherwise.
    Expired entries are not actively cleaned up here — the strategy's
    [record_sticky_choice] overwrites stale entries naturally on the
    next success.  Tests can call {!clear_sticky} for determinism. *)

val clear_sticky : unit -> unit
(** Remove every sticky entry.  Test helper. *)

(** {1 Round-robin state} *)

val rotate_round_robin : cascade:string -> bound:int -> int
(** [rotate_round_robin ~cascade ~bound] returns the current cursor
    value modulo [bound] and atomically advances the cursor by 1.
    Returns [0] when [bound <= 0] (caller is responsible for
    treating the empty list as a no-op).  Atomic — safe under
    contention. *)

val peek_round_robin : cascade:string -> int
(** Return the current cursor value without advancing.  Test helper. *)

val clear_round_robin : unit -> unit
(** Reset every cursor to 0.  Test helper. *)

(** {1 Bulk reset} *)

val clear_all : unit -> unit
(** Equivalent to {!clear_sticky} + {!clear_round_robin}.  Used by
    tests and by future hot-reload code paths. *)
