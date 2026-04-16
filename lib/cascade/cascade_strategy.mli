(** Pluggable cascade strategy — selects and orders provider candidates.

    A strategy is a pure transformation that takes the raw candidate list
    plus runtime signals (health, capacity, wall clock) and returns the
    ordered subset to attempt in a single cascade cycle.  It never calls
    IO; it never mutates state.  When a cycle exhausts without success,
    the caller re-invokes the strategy for the next cycle (optionally
    after a backoff sleep); the strategy can return a different ordering
    because health and capacity signals may have changed.

    S5 (priority_tier), S6 (sticky), S7 (round_robin) require per-cascade
    external state and are deferred to a follow-up PR.

    @since 0.9.6 *)

(** {1 Signal context — what the strategy can read} *)

type signal_ctx = {
  health : Cascade_health_tracker.t;
  (** Health tracker for success_rate, cooldown, effective_weight. *)

  capacity : string -> Cascade_throttle.capacity_info option;
  (** Per-endpoint capacity probe keyed by [base_url].  Returns [None]
      when the endpoint is not in the throttle table (CLI providers,
      unprobed HTTP providers).  The strategy must treat [None] as
      "unknown → optimistically available" to avoid false starvation. *)

  now : float;
  (** Current wall clock time (seconds since epoch).  Passed in for
      determinism in tests. *)

  rand_int : int -> int;
  (** Random integer generator in [0, n).  Passed in for determinism
      in tests. *)
}

(** {1 Cycle policy — orthogonal to strategy kind} *)

type cycle_policy = {
  max_cycles : int;
  (** Maximum cycle count before returning [Cascade_exhausted].
      [max_cycles = 1] means the current linear failover behaviour
      (no retry after first pass). *)

  backoff_base_ms : int;
  (** Exponential backoff base in milliseconds.
      Actual sleep = [min backoff_cap_ms (backoff_base_ms * 2^(cycle-1))]. *)

  backoff_cap_ms : int;
  (** Upper bound on per-cycle backoff. *)
}

val default_cycle_policy : cycle_policy
(** [{ max_cycles = 1; backoff_base_ms = 500; backoff_cap_ms = 10_000 }].
    Backward-compatible with pre-strategy behaviour (linear failover). *)

val backoff_ms : cycle_policy -> cycle:int -> int
(** [backoff_ms policy ~cycle] returns the sleep duration for [cycle]
    before the next cascade attempt.  [cycle] is 1-indexed: the first
    retry after cycle 0 uses [backoff_ms ~cycle:1]. *)

(** {1 Strategy kind} *)

type kind =
  | Failover
    (** S1 — input order preserved, always-available.  Equivalent to
        the pre-strategy behaviour (linear failover). *)

  | Capacity_aware
    (** S2 — filters candidates whose endpoint capacity reports
        [process_available = 0].  Unknown capacity is treated as
        available (fail-open). *)

  | Weighted_random
    (** S3 — weighted shuffle using [config_weight * success_rate].
        Cooled-down providers (effective_weight = 0) are filtered,
        with the order_weighted_entries guarantee that at least one
        provider survives to avoid starvation. *)

  | Circuit_breaker_cycling
    (** S4 — S2 capacity filter AND [is_in_cooldown] exclusion,
        combined with [max_cycles > 1] and exponential backoff.  The
        circuit-breaker semantics live in Cascade_health_tracker; this
        strategy is the policy that reads them. *)

val kind_to_string : kind -> string
val parse_kind : string -> (kind, string) result
(** [parse_kind s] returns [Ok kind] for known names, [Error msg] for
    unknown values.  Callers should warn-and-fallback to [Failover]
    rather than raise, to keep keeper startup resilient to config typos. *)

(** {1 Strategy value} *)

type t = {
  kind : kind;
  cycle : cycle_policy;
}

val failover : t
(** [{ kind = Failover; cycle = default_cycle_policy }].  What callers
    receive when no per-cascade strategy is configured. *)

(** {1 Candidate adapter}

    Strategies read three pieces of information from each candidate:
    the health-tracker key (typically [model_id]), the capacity key
    (typically [base_url]), and the weight used by weighted_random.
    We expose an adapter so tests can drive the strategy with simple
    in-memory records, and production wires it to
    [Llm_provider.Provider_config.t] plus the cascade's configured
    weights.  The adapter is resolution-time data; strategies do not
    mutate it. *)

type 'a adapter = {
  health_key : 'a -> string;
  capacity_key : 'a -> string;
  weight : 'a -> int;
}

(** {1 Ordering} *)

val order_candidates :
  t ->
  adapter:'a adapter ->
  ctx:signal_ctx ->
  cycle:int ->
  'a list ->
  'a list
(** [order_candidates t ~adapter ~ctx ~cycle candidates] is the ordered
    subset of [candidates] to attempt in [cycle].  Returns the empty
    list when no candidate is usable right now (e.g. all endpoints
    report [process_available = 0] for S2), in which case the caller
    should either advance to the next cycle with a backoff or report
    [Cascade_exhausted].

    This function is pure and must not perform IO.  [cycle] is
    0-indexed (first cycle = 0).  Some strategies (notably
    Weighted_random) consult [ctx.rand_int]; tests can pass a
    deterministic RNG. *)
