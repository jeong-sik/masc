(** Pluggable cascade strategy — selects and orders provider candidates.

    A strategy is a pure transformation that takes the raw candidate list
    plus runtime signals (health, capacity, wall clock) and returns the
    ordered subset to attempt in a single cascade cycle.  It never calls
    IO; it never mutates state.  When a cycle exhausts without success,
    the caller re-invokes the strategy for the next cycle (optionally
    after a backoff sleep); the strategy can return a different ordering
    because health and capacity signals may have changed.

    The shipped runtime supports two operator-visible strategies:
    [Failover] and [Priority_tier].  Older experimental strategies were
    retired from the public ADT so they cannot be selected accidentally
    by config, tests, or internal callers.

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

  keeper_name : string;
  (** Owning keeper.  Kept in the signal context for call-site stability;
      current shipped strategies do not read it. *)

  cascade_name : Cascade_ref.runtime_name;
  (** Cascade identifier (the [<name>] in [<name>_models]).  Used for
      priority-tier starvation telemetry. *)
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

  | Priority_tier
    (** S2 — providers grouped into ordered tiers via [tiers] in {!t}.
        Cycle [n] only considers tier [n] (clamped to last tier).
        Within a tier, capacity-aware filtering is applied; the tier
        is "active" iff at least one of its providers survives the
        filter, otherwise the cycle yields the empty list and the
        caller advances to the next cycle (i.e. next tier).
        @since 0.9.7 *)
[@@deriving tla]
(** [@@deriving tla] generates [to_tla_symbol] (kind -> string),
    [all_symbols] (string list), and [all_states] (kind list) so
    [specs/boundary/CascadeStrategy.tla] string literals stay
    drift-free with the OCaml type. PPX adoption per Cycle 18. *)

val kind_to_string : kind -> string

val all_kinds : kind list
(** All [kind] constructors in declaration order.  Adding a new
    constructor forces compile errors in [kind_to_string] (which
    powers [valid_kind_strings] used by the [parse_kind] error
    message), so the internal "expected one of" list stays in sync
    automatically.  Issue #8603. *)

val valid_kind_strings : string list
(** Wire-format names for {!all_kinds}, derived via {!kind_to_string}. *)

val config_kind_strings : string list
(** Strategy names accepted from operator cascade configuration.

    This intentionally matches {!valid_kind_strings}: retired strategy
    constructors no longer exist in the public ADT. *)

val parse_kind : string -> (kind, string) result
(** [parse_kind s] returns [Ok kind] for known names, [Error msg] for
    unknown values.  The [Error] message lists {!valid_kind_strings}
    so it stays in sync with the variant.  Callers should warn-and-fallback
    to [Failover] rather than raise, to keep keeper startup resilient to
    config typos. *)

val parse_config_kind : string -> (kind, string) result
(** [parse_config_kind s] is the parser for operator-provided cascade
    configuration. *)

(** {1 Strategy value} *)

type t = {
  kind : kind;
  cycle : cycle_policy;

  tiers : string list list;
  (** Used only by [Priority_tier].  Each inner list is the set of
      provider keys (matched against [adapter.health_key]) that form
      one tier; outer order is tier order (tier 0 = highest priority).
      Empty list when the strategy is not [Priority_tier].
      @since 0.9.7 *)
}

val failover : t
(** [{ kind = Failover; cycle = default_cycle_policy; tiers = [] }].
    What callers receive when no per-cascade strategy is configured. *)

(** {1 Candidate adapter}

    Strategies read candidate identity from the health-tracker key
    (typically provider-scoped) and capacity key (typically [base_url]).
    We expose an adapter so tests can drive the strategy with simple
    in-memory records, and production wires it to
    [Llm_provider.Provider_config.t].  The adapter is resolution-time
    data; strategies do not mutate it. *)

type 'a adapter = {
  health_key : 'a -> string;
  capacity_key : 'a -> string;
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
    0-indexed (first cycle = 0). *)

(** {1 Completion hook} *)

val record_choice :
  t ->
  ctx:signal_ctx ->
  provider_key:string ->
  unit
(** [record_choice t ~ctx ~provider_key] is invoked by the cascade
    caller after a successful attempt completes (HTTP 200, FSM
    [Accept]/[Accept_on_exhaustion]).  Current shipped strategies are
    stateless, so this is a no-op retained for caller stability. *)
