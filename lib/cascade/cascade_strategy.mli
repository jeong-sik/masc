(** Pluggable cascade strategy — selects and orders provider candidates.

    A strategy is a pure transformation that takes the raw candidate list
    plus runtime signals (health, capacity, wall clock) and returns the
    ordered subset to attempt in a single cascade cycle.  It never calls
    IO; it never mutates state.  When a cycle exhausts without success,
    the caller re-invokes the strategy for the next cycle (optionally
    after a backoff sleep); the strategy can return a different ordering
    because health and capacity signals may have changed.

    Phase A (S1–S4) is purely stateless.  Phase B introduces three
    additional kinds — [Priority_tier], [Sticky], [Round_robin] — that
    consult per-cascade-name state owned by {!Cascade_state}.  The
    ordering function remains read-only; mutations happen via the
    explicit {!record_choice} hook the cascade caller invokes after a
    successful attempt.

    @since 0.9.6
    @since 0.9.7 Phase B (Priority_tier / Sticky / Round_robin) *)

(** {1 Scoring parameters — configurable per-cascade} *)

(** Configurable scoring parameters for the [Weighted_random] strategy.

    Each field has a documented default matching the pre-existing
    hardcoded values.  Values can be overridden per-cascade via TOML
    profile fields (e.g. [latency_baseline_ms], [rate_limit_decay_base])
    or globally via the corresponding [MASC_CASCADE_*] environment
    variables.

    @since 0.184.0 *)
type scoring_params = {
  latency_baseline_ms : float;
  (** Milliseconds.  Provider p50 above this value incurs a fractional
      score penalty.  Default 2000.0.  Env var:
      [MASC_CASCADE_LATENCY_BASELINE_MS]. *)

  rate_limit_recency_window_s : float;
  (** Seconds.  Lookback window for counting recent 429 events.
      Default 60.0.  Set to 0.0 to disable.  Env var:
      [MASC_CASCADE_RATE_LIMIT_RECENCY_WINDOW_S]. *)

  rate_limit_decay_base : float;
  (** Per-event decay multiplier in (0.0, 1.0).  Default 0.5.  Env var:
      [MASC_CASCADE_RATE_LIMIT_DECAY_BASE]. *)

  rate_limit_skip_after : int;
  (** Hard-skip threshold for 429 events.  Default 3.  Env var:
      [MASC_CASCADE_RATE_LIMIT_SKIP_AFTER]. *)

  server_error_recency_window_s : float;
  (** Seconds.  Lookback window for counting recent 5xx events.
      Default 120.0.  Set to 0.0 to disable.  Env var:
      [MASC_CASCADE_SERVER_ERROR_RECENCY_WINDOW_S]. *)

  server_error_decay_base : float;
  (** Per-event decay multiplier in (0.0, 1.0).  Default 0.6.  Env var:
      [MASC_CASCADE_SERVER_ERROR_DECAY_BASE]. *)

  server_error_skip_after : int;
  (** Hard-skip threshold for 5xx events.  Default 4.  Env var:
      [MASC_CASCADE_SERVER_ERROR_SKIP_AFTER]. *)
}

val default_scoring_params : scoring_params
(** Default scoring parameters using env-var overrides with compiled
    fallbacks.  This is the value used by {!failover} and by callers
    that do not load a TOML profile. *)

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
  (** Owning keeper.  Used by [Sticky] to key its state.  Set to ["" ]
      when the cascade is invoked outside a keeper context (CLI,
      bootstrap probes); [Sticky] then degrades to a per-cascade-only
      affinity (still useful), and other kinds ignore the field.

      @since 0.9.7 *)

  cascade_name : Keeper_cascade_profile.runtime_name;
  (** Cascade identifier (the [<name>] in [<name>_models]).  Used by
      [Sticky] and [Round_robin] to scope their state.  Required for
      stateful kinds; tolerated as [Runtime_name "" ] for stateless kinds.
      Rendered to string only at the {!Cascade_state} boundary.

      @since 0.9.7 *)
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

val latency_score_for_provider :
  Cascade_health_tracker.t -> provider_key:string -> float
(** [latency_score_for_provider health ~provider_key] returns a
    [0.0–1.0] multiplier reflecting how the provider's recent p50
    response time compares to {!latency_baseline_ms}.

    - p50 ≤ baseline → [1.0] (no penalty).
    - p50 > baseline → fractional score, decaying as [baseline / p50].
    - Unknown provider, no latency samples, or latency tracking disabled
      ([latency_ring_size <= 0]) → [1.0] (optimistic default).

    Used internally by {!Weighted_random} to prefer faster providers
    when success rates are comparable.  Exposed for inspection /
    testability — strategies do not need to call this directly.

    @since 0.181.0 (PR3 of cascade resilience track) *)

val rate_limit_score_for_provider :
  Cascade_health_tracker.t -> provider_key:string -> float
(** [rate_limit_score_for_provider health ~provider_key] returns a
    [0.0–1.0] multiplier that decays with the count of recent
    [Soft_rate_limited] events for [provider_key].

    Formula: [score = decay_base ^ count] until [count] reaches the
    hard-skip threshold, where [count] is the number of soft rate-limit
    events recorded in the last 60 seconds (default window — env
    [MASC_CASCADE_RATE_LIMIT_RECENCY_WINDOW_S]).  Default decay base 0.5
    (env [MASC_CASCADE_RATE_LIMIT_DECAY_BASE]); default hard-skip
    threshold is 3 (env [MASC_CASCADE_RATE_LIMIT_SKIP_AFTER], 0 disables).

    - Unknown provider, no recent events, or window disabled
      ([RECENCY_WINDOW_S <= 0]) → [1.0] (optimistic default).
    - Cooled-down provider → still scored normally; [effective_weight]
      already returns 0 when in cooldown, and multiplying that by any
      fractional score preserves zero.

    Used internally by {!Weighted_random} so a provider that just hit
    a sustained 429 burst gets skipped instead of remaining eligible
    with a tiny non-zero probability after its short cooldown expires.
    Exposed for inspection / testability — strategies do not need to
    call this directly.

    @since 0.183.0 (PR3b of cascade resilience track) *)

val server_error_score_for_provider :
  Cascade_health_tracker.t -> provider_key:string -> float
(** [server_error_score_for_provider health ~provider_key] returns a
    [0.0–1.0] multiplier that decays with the count of recent
    [Failure] events (HTTP 5xx / provider errors) for [provider_key].

    Formula: [score = decay_base ^ count] until [count] reaches the
    hard-skip threshold.  Default window 120 s (env
    [MASC_CASCADE_SERVER_ERROR_RECENCY_WINDOW_S]), default decay base 0.6
    (env [MASC_CASCADE_SERVER_ERROR_DECAY_BASE]), default hard-skip
    threshold 4 (env [MASC_CASCADE_SERVER_ERROR_SKIP_AFTER], 0 disables).

    When [se = 0.0] the provider is excluded from the weighted pick for
    this ordering pass and [metric_cascade_server_error_skip_total] is
    incremented.

    - Unknown provider, no recent failures, or window disabled → [1.0].
    - Interacts with [rate_limit_score_for_provider]: a provider in both
      a 429 burst and a 500 storm gets both penalties multiplied.

    @since #12797 *)

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

  | Priority_tier
    (** S5 — providers grouped into ordered tiers via [tiers] in {!t}.
        Cycle [n] only considers tier [n] (clamped to last tier).
        Within a tier, capacity-aware filtering is applied; the tier
        is "active" iff at least one of its providers survives the
        filter, otherwise the cycle yields the empty list and the
        caller advances to the next cycle (i.e. next tier).
        @since 0.9.7 *)

  | Sticky
    (** S6 — per-[(keeper_name, cascade_name)] affinity.  When a
        previous successful provider is still within [sticky_ttl_ms],
        return only that provider as the singleton ordering.  When no
        sticky entry exists or it has expired, fall back to plain
        Failover ordering.  The cascade caller is responsible for
        invoking {!record_choice} after a successful attempt so the
        affinity is recorded.
        @since 0.9.7 *)

  | Round_robin
    (** S7 — per-cascade rotation cursor.  The first attempt of each
        cascade call rotates the input list by the current cursor
        value (mod list length), then advances the cursor.  Within a
        single cycle, the rotated order is preserved (Failover
        within); cross-call fairness comes from the cursor.
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
    message), so the operator-visible "expected one of" list stays
    in sync automatically.  Issue #8603. *)

val valid_kind_strings : string list
(** Wire-format names for {!all_kinds}, derived via {!kind_to_string}. *)

val parse_kind : string -> (kind, string) result
(** [parse_kind s] returns [Ok kind] for known names, [Error msg] for
    unknown values.  The [Error] message lists {!valid_kind_strings}
    so it stays in sync with the variant.  Callers should warn-and-fallback
    to [Failover] rather than raise, to keep keeper startup resilient to
    config typos. *)

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

  sticky_ttl_ms : int;
  (** Used only by [Sticky].  Time-to-live for a recorded sticky
      choice in milliseconds.  Defaults to [300_000] (5 minutes) when
      the strategy is [Sticky]; ignored otherwise.  Values [<= 0]
      effectively disable affinity (every call is a fresh Failover).
      @since 0.9.7 *)

  scoring : scoring_params;
  (** Scoring parameters used by [Weighted_random] to compute per-provider
      weight multipliers.  Defaults to {!default_scoring_params}.
      Configurable per-cascade via TOML profile fields.
      Stateless strategies ([Failover], [Capacity_aware]) ignore
      this field. *)
}

val failover : t
(** [{ kind = Failover; cycle = default_cycle_policy; tiers = [];
       sticky_ttl_ms = 0 }].  What callers receive when no per-cascade
    strategy is configured. *)

val default_sticky_ttl_ms : int
(** [300_000] (5 minutes).  The fallback TTL used by config loaders
    when [Sticky] is selected without an explicit
    [<name>_sticky_ttl_ms].
    @since 0.9.7 *)

(** {1 Candidate adapter}

    Strategies read three pieces of information from each candidate:
    the health-tracker key (typically provider-scoped), the capacity key
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
    deterministic RNG.

    Stateful kinds may consult {!Cascade_state} (which is technically
    side-effectful for [Round_robin] because it advances a cursor on
    every call); the function still returns deterministic output for
    a given state snapshot, and tests can reset the snapshot via
    {!Cascade_state.clear_all}. *)

(** {1 Stateful hooks}

    Phase B kinds need a write path so the cascade caller can record
    successful attempts.  Phase A kinds ignore these hooks. *)

val record_choice :
  t ->
  ctx:signal_ctx ->
  provider_key:string ->
  unit
(** [record_choice t ~ctx ~provider_key] is invoked by the cascade
    caller after a successful attempt completes (HTTP 200, FSM
    [Accept]/[Accept_on_exhaustion]).  For [Sticky], stores
    [(ctx.keeper_name, ctx.cascade_name) -> provider_key] in
    {!Cascade_state} with [t.sticky_ttl_ms].  For all other kinds
    (including [Round_robin], whose cursor was advanced at order
    time), this is a no-op.

    Idempotent: calling twice for the same attempt simply overwrites
    the same entry.  Safe under concurrent fibers via
    {!Cascade_state} mutex.

    @since 0.9.7 *)
