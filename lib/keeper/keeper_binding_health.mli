(** Reactive health tracking for runtime providers.

    Tracks per-provider success/failure rates using a rolling time window.
    Providers in cooldown (consecutive failures exceed threshold) are
    temporarily skipped.

    Thread-safe via internal [Stdlib.Mutex].

    @since 0.137.0 *)

(** {1 Runtime configuration (env-driven, read once at module load)}

    The env var prefix is [MASC_RUNTIME_*]. *)

val window_sec : float
(** Rolling window duration in seconds.  Default 300.0 (5 min). *)

val cooldown_threshold : int
(** Consecutive failures before cooldown activates.  Default 3. *)

val cooldown_sec : float
(** Cooldown duration in seconds.  Default 30.0. *)

val hard_quota_cooldown_sec : float
(** Cooldown duration applied immediately on a hard-quota-classified error
    (balance depleted, monthly quota reached, resource exhausted).  Unlike
    {!cooldown_sec}, no threshold is required — one hard-quota event is
    enough.  Default 3600.0 (1h).

    Env: [MASC_RUNTIME_HARD_QUOTA_COOLDOWN_SEC].

    @since 0.161.0 *)

val terminal_failure_cooldown_sec : float
(** Cooldown duration applied immediately on a terminal structural
    provider/adapter failure, such as a provider CLI resumable-session conflict.
    Unlike {!cooldown_sec}, no threshold is required.  Default 3600.0 (1h).

    Env: [MASC_RUNTIME_TERMINAL_FAILURE_COOLDOWN_SEC]. *)

val server_error_cooldown_sec : float
(** Cooldown duration applied immediately on upstream HTTP 5xx server errors.
    Default 300.0 (5 min), env [MASC_RUNTIME_SERVER_ERROR_COOLDOWN_SEC].

    This is intentionally separate from {!cooldown_sec}: thresholded 30s
    failure cooldown can expire between scheduled keeper cycles, repeatedly
    paging operators for the same unhealthy provider lane. *)

val soft_rate_limit_cooldown_sec : float
(** Default cooldown applied immediately on a transient HTTP 429 (soft
    rate-limit) when no Retry-After hint is available.  Distinct from
    {!cooldown_sec} because a single 429 should already deprioritize the
    provider for the remainder of the current runtime cycle — the
    [cooldown_threshold] count-to-three semantics are wrong for transient
    rate limits.  Default 10.0 (10s).

    Env: [MASC_RUNTIME_SOFT_RATE_LIMIT_COOLDOWN_SEC]. *)

val soft_rate_limit_max_clamp_sec : float
(** Upper clamp for caller-supplied [retry_after_s] when recording a soft
    rate-limit event.  Providers occasionally return Retry-After values
    measured in minutes or hours; honoring those literally would silently
    promote a transient 429 into a long blackout.  Anything that exceeds
    this clamp should be classified as {!record_hard_quota} by the
    caller, not as a soft rate-limit.  Default 120.0 (2 min).

    Env: [MASC_RUNTIME_SOFT_RATE_LIMIT_MAX_CLAMP_SEC]. *)

val default_capacity_backpressure_backoff_sec : float
(** Synthetic typed backoff applied when an upstream [Capacity_backpressure]
    error arrives with [retry_after_sec = None].  Without this, the runtime
    rotates immediately onto the next candidate and frequently lands back
    on the same degraded provider before any recovery window has elapsed.
    Default 5.0 (5s) — shorter than {!soft_rate_limit_cooldown_sec} because
    capacity backpressure is a short-window signal (peers usually recover
    faster than 429-bearing providers), but non-zero so the runtime does
    not immediately re-select the just-rejected provider.

    Env: [MASC_RUNTIME_CAPACITY_BACKPRESSURE_DEFAULT_BACKOFF_SEC]. *)

val latency_ring_size : int
(** Number of recent successful-call latencies retained per provider for
    percentile observation.  The ring buffer is per-provider; older
    samples are silently overwritten as new successes arrive.

    A small ring is intentional — strategy decisions only need a
    "recent" sense of how fast the provider has been responding, not a
    full distribution.  100 samples cover ~5–15 minutes of activity for
    a busy provider while staying small enough to sort cheaply on every
    [provider_info] read.

    Default 100, env [MASC_RUNTIME_LATENCY_RING_SIZE].  Values [<= 0]
    disable latency tracking entirely (the ring is treated as empty and
    [p50_latency_ms] / [p95_latency_ms] always return [None]). *)

val confidence_ring_size : int
(** Number of recent avg-log-probability samples retained per provider.
    Mirrors {!latency_ring_size} semantics: ring buffer, drop-oldest,
    lazy allocation.  Default 100, env
    [MASC_RUNTIME_CONFIDENCE_RING_SIZE].  Values [<= 0] disable
    confidence tracking. *)

val cost_ring_size : int
(** Number of recent per-request cost samples retained per provider.
    Mirrors {!latency_ring_size} semantics: ring buffer, drop-oldest,
    lazy allocation.  Default 100, env [MASC_RUNTIME_COST_RING_SIZE].
    Values [<= 0] disable cost tracking.  @since 0.191.0 *)


(** Opaque health tracker state. *)
type t

(** Typed wrapper for provider-health error classifications. Dashboard
    fingerprints and summaries continue to render the stable string label. *)
type error_kind = private Error_kind of string

val error_kind_of_string : string -> error_kind
val error_kind_to_string : error_kind -> string

(** Create a new empty tracker. *)
val create : unit -> t

(** Durable provider state that can be restored after process restart.

    Cooldown, failure count, and error fingerprints prevent a restart from
    immediately retrying a provider that was just circuit-broken.  The optional
    routing hints seed the bounded latency/confidence/cost rings from the last
    persisted snapshot so weighted runtime selection does not restart with a
    fully cold view of recent provider performance. *)
type provider_restore = {
  restore_provider_key : string;
  restore_consecutive_failures : int;
  restore_cooldown_until : float option;
  restore_last_failure_at : float option;
  restore_top_fingerprints : (string * int) list;
  restore_latency_ms : float option;
  restore_confidence : float option;
  restore_cost_usd : float option;
}

(** Restore durable provider state into a tracker.
    Returns the number of non-empty provider rows applied. *)
val restore_providers : t -> provider_restore list -> int

(** Record a successful provider call. Clears cooldown and resets
    consecutive failure counter.

    Optional [latency_ms] is the wall-clock duration of the provider
    call in milliseconds.  When supplied, it is appended to a small
    per-provider ring buffer and surfaced as [p50_latency_ms] /
    [p95_latency_ms] on {!provider_info}.  Strategies can use the
    p50/p95 to prefer faster providers when success rates are
    comparable.  Negative or non-finite values are silently dropped
    (the success itself is still recorded). *)
val record_success :
  t ->
  provider_key:string ->
  ?latency_ms:float ->
  ?confidence:float ->
  ?cost_usd:float ->
  unit ->
  unit

(** Record a failed provider call. Increments consecutive failure
    counter; triggers cooldown when threshold is reached.

    Optional [error_kind] (e.g. "auth", "timeout", "schema") and
    [error_reason] (raw error string) are folded into a stable
    fingerprint [error_kind|hash8(reason)] and accumulated in
    [provider_info.top_fingerprints] for observability. Both default
    to [None] (unclassified) which is still recorded under the synthetic
    fingerprint ["unclassified"].

    @since 0.174.0 *)
val record_failure :
  t ->
  provider_key:string ->
  ?error_kind:error_kind ->
  ?error_reason:string ->
  unit ->
  unit

(** Record a provider call where the response arrived but was rejected
    by the runtime's [accept] predicate (e.g. empty body, schema gate).

    Behaves like {!record_failure} for cooldown / weight purposes — a
    provider whose outputs are consistently unusable should be skipped —
    but is counted separately in [provider_info.rejected_in_window] so
    the dashboard can distinguish "provider down" from "provider returns
    garbage".

    Prior to 0.160.0 this path called {!record_success} (the response
    technically arrived), which silently masked gate drift: a provider
    could rank 100% healthy while every call fell through to the next
    runtime.

    See {!record_failure} for [error_kind] / [error_reason] semantics.

    @since 0.160.0 *)
val record_rejected :
  t ->
  provider_key:string ->
  ?error_kind:error_kind ->
  ?error_reason:string ->
  unit ->
  unit

(** Record a provider call that failed with a hard-quota error (balance
    depleted, monthly quota reached, resource exhausted — classified
    upstream via [Llm_provider.Retry.is_hard_quota]).

    Unlike {!record_failure}, this triggers an immediate long cooldown
    ({!hard_quota_cooldown_sec}, default 1h) with no threshold — a
    provider whose account is out of credit will not recover within the
    regular [cooldown_sec] window, and weighted_random re-selection just
    wastes runtime turns.

    Preserves an already-longer cooldown if one exists (no regression).
    Counts toward [consecutive_failures] for dashboard continuity and
    toward [events_in_window] in {!provider_info}.

    See {!record_failure} for [error_kind] / [error_reason] semantics.

    @since 0.161.0 *)
val record_hard_quota :
  t ->
  provider_key:string ->
  ?error_kind:error_kind ->
  ?error_reason:string ->
  unit ->
  unit

(** Record a provider call that failed with a terminal structural
    provider/adapter error.

    This uses immediate long cooldown semantics like {!record_hard_quota},
    but is kept distinct from quota exhaustion so the caller can classify
    adapter/session failures without pretending the account is out of credit.

    See {!record_failure} for [error_kind] / [error_reason] semantics. *)
val record_terminal_failure :
  t ->
  provider_key:string ->
  ?error_kind:error_kind ->
  ?error_reason:string ->
  unit ->
  unit

(** Record an upstream HTTP 5xx server error.

    A single 5xx triggers a medium cooldown so autonomous keeper cycles do not
    repeatedly dispatch into the same unhealthy cloud lane after OAS has already
    exhausted its provider-owned retry/backoff. *)
val record_server_error :
  t ->
  provider_key:string ->
  ?error_kind:error_kind ->
  ?error_reason:string ->
  unit ->
  unit

(** Record a transient HTTP 429 (rate-limit) response.

    Unlike {!record_failure}, a single soft rate-limit triggers an
    immediate short cooldown so the runtime can fall over to the next
    candidate within the same turn instead of returning to the same
    provider on the next selection tick.  No threshold applies.

    [retry_after_s] is the value parsed from the upstream HTTP
    [Retry-After] header (RFC 7231: integer seconds or HTTP-date).
    When present, cooldown is set to [min retry_after_s
    soft_rate_limit_max_clamp_sec]; otherwise cooldown defaults to
    {!soft_rate_limit_cooldown_sec}.  Negative or zero values fall back
    to the default.  Caller is responsible for upgrading sustained 429
    bursts to {!record_hard_quota} when appropriate (e.g. monthly quota
    boundaries) — this function intentionally never extends past
    [soft_rate_limit_max_clamp_sec] regardless of header value.

    Preserves an already-longer cooldown if one exists (no regression).

    See {!record_failure} for [error_kind] / [error_reason] semantics. *)
val record_soft_rate_limited :
  t ->
  provider_key:string ->
  ?retry_after_s:float ->
  ?error_kind:error_kind ->
  ?error_reason:string ->
  unit ->
  unit

(** [record_capacity_backpressure] is like {!record_soft_rate_limited}
    but tags the event as [Capacity_backpressure] and uses
    [default_capacity_backpressure_backoff_sec] as the synthetic default.
    A single capacity-exhaustion event triggers immediate cooldown so the
    runtime skips the provider for the rest of the cycle without waiting
    for the [cooldown_threshold] consecutive-failure count.

    See {!record_failure} for [error_kind] / [error_reason] semantics. *)
val record_capacity_backpressure :
  t ->
  provider_key:string ->
  ?retry_after_s:float ->
  ?error_kind:error_kind ->
  ?error_reason:string ->
  now:float ->
  unit ->
  unit

(** Drop tracker entries whose rolling window is empty AND whose cooldown
    has expired.  Intended as opportunistic maintenance — idle providers
    carry no information but keep growing the hashtable (and pollute the
    dashboard).

    @return number of entries evicted.
    @since 0.160.0 *)
val evict_idle : t -> int

(** Success rate in the rolling window (0.0 to 1.0).
    Returns 1.0 for unknown providers (optimistic default). *)
val success_rate : t -> provider_key:string -> float

(** Whether the provider is currently in cooldown (should be skipped). *)
val is_in_cooldown : t -> provider_key:string -> bool

(** Whether the provider is in capacity backpressure cooldown specifically.
    Used for pre-admission filtering to skip providers that recently
    signalled capacity exhaustion, avoiding wasted OAS body budget. *)
val is_capacity_constrained : t -> provider_key:string -> bool

(** Compute effective weight for weighted runtime selection.

    [effective_weight = config_weight * success_rate]

    Returns 0 for providers in cooldown.
    Returns full [config_weight] for unknown providers. *)
val effective_weight : t -> provider_key:string -> config_weight:int -> int

(** Human-readable summary for debugging/telemetry. *)
val provider_summary : t -> provider_key:string -> string

(** Outcome variant exposed for {!recent_outcome_count} window queries and the
    [cooldown_cause] field of {!provider_info}.  Mirrors the internal
    classification — the internal [outcome] type is kept abstract elsewhere to
    keep the recording surface narrow.

    @since 0.183.0 *)
type outcome_kind =
  | Outcome_success
  | Outcome_failure
  | Outcome_rejected
  | Outcome_hard_quota
  | Outcome_terminal_failure
  | Outcome_server_error
  | Outcome_soft_rate_limited
  | Outcome_capacity_backpressure

(** Structured summary for telemetry/dashboard consumption.

    @since 0.139.0 *)
type provider_info = {
  provider_key : string;
  success_rate : float;               (** 0.0 to 1.0, 1.0 if unknown *)
  consecutive_failures : int;
  in_cooldown : bool;
  cooldown_expires_at : float option; (** Unix timestamp, Some iff [in_cooldown] *)
  cooldown_cause : outcome_kind option;
  (** The outcome that armed the active cooldown window, [Some] iff
      [in_cooldown] and the arming cause is known (a cooldown restored from
      persistence reports [None] until re-armed).  The pre-dispatch cooldown
      gate uses this to distinguish deterministic causes (which escalate) from
      transient ones (which stay auto-recoverable).  #23438. *)
  events_in_window : int;             (** Events retained in rolling window *)
  rejected_in_window : int;           (** Subset of [events_in_window] whose outcome was [Rejected]. @since 0.160.0 *)
  top_fingerprints : (string * int) list;
  (** Top-N error fingerprints with cumulative counts (descending), capped
      at 3.  Fingerprint format: ["error_kind|hash8(error_reason)"] —
      built by {!record_failure} / {!record_rejected} / {!record_hard_quota}
      from caller-provided classifications.  Empty list when no failures
      have been recorded.  @since 0.174.0 *)
  last_failure_at : float option;
  (** Unix timestamp of the most recent non-success event, or [None] if
      none.  Phase 0 observability anchor for "did this provider fail
      recently".  @since 0.174.0 *)
  p50_latency_ms : float option;
  (** 50th-percentile (median) of recent successful-call latencies in
      milliseconds, computed from the per-provider ring buffer
      (see {!latency_ring_size}).  [None] when no latency samples have
      been recorded — either because [record_success] was never called
      with [~latency_ms], or because [latency_ring_size <= 0].  Strategies
      may use this to prefer faster providers when success rates and
      cooldown state are comparable.  @since 0.180.0 *)
  p95_latency_ms : float option;
  (** 95th-percentile of recent successful-call latencies in milliseconds.
      Same source and [None] semantics as {!p50_latency_ms}.  Useful for
      flagging tail-latency regressions in observability dashboards.
      @since 0.180.0 *)
  latency_samples : int;
  (** Number of latency samples currently retained in the ring buffer.
      [0] iff both percentile fields are [None].  Bounded by
      {!latency_ring_size}.  @since 0.180.0 *)
  avg_confidence : float option;
  (** Mean of recent avg-log-probability samples from the per-provider
      confidence ring.  [None] when no samples have been recorded.
      Lower (more negative) values indicate higher response confidence.
      @since 0.183.0 *)
  confidence_samples : int;
  (** Number of confidence samples currently retained.  [0] iff
      [avg_confidence] is [None].  Bounded by {!confidence_ring_size}.
      @since 0.183.0 *)
  avg_cost_usd : float option;
  (** Mean of recent per-request cost samples from the per-provider cost
      ring.  [None] when no cost data has been recorded.  Used as input
      to the composite health score's cost component — providers with
      lower average cost score higher.
      @since 0.191.0 *)
  cost_samples : int;
  (** Number of cost samples currently retained.  [0] iff
      [avg_cost_usd] is [None].  Bounded by {!cost_ring_size}.
      @since 0.191.0 *)
  health_score : float;
  (** Composite health score (0.0–1.0) combining success_rate,
      speed_score (from p95 latency), and cost_score.
      @since 0.190.0 *)
}

(** Structured info for a single provider. Returns [None] if untracked.
    @since 0.139.0 *)
val provider_info : t -> provider_key:string -> provider_info option

(** Snapshot of all tracked providers.
    Useful for dashboards and telemetry endpoints.
    @since 0.139.0 *)
val all_providers : t -> provider_info list

(** [recent_outcome_count t ~provider_key ~outcome ~window_s] returns the
    number of events of [outcome] recorded for [provider_key] within the
    last [window_s] seconds.

    Useful as a recency signal for adaptive weighting — e.g. counting
    [Outcome_soft_rate_limited] events in a 60s window so the strategy
    can de-prioritise providers that just hit a 429 burst, even after
    their cooldown expires.

    Returns 0 for unknown providers, when no matching event is in
    window, or when [window_s] is non-positive.  The window is
    silently clamped to the rolling event-retention window of the
    tracker (see {!window_sec}) — events older than that have already
    been pruned and cannot be counted.

    @since 0.183.0 *)
val recent_outcome_count :
  t ->
  provider_key:string ->
  outcome:outcome_kind ->
  window_s:float ->
  int

(** Global singleton tracker shared across all runtime calls. *)
val global : t

val check_circuit_breaker : t -> provider_key:string -> (unit, string) result
(** Check whether the provider cooldown gate allows a request. *)
