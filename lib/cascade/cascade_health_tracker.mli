(** Reactive health tracking for cascade providers.

    Tracks per-provider success/failure rates using a rolling time window.
    Providers in cooldown (consecutive failures exceed threshold) are
    temporarily skipped.

    Thread-safe via internal [Stdlib.Mutex].

    @since 0.137.0 *)

(** {1 Runtime configuration (env-driven, read once at module load)}

    The env var prefix is [MASC_CASCADE_*]; [OAS_CASCADE_*] is accepted
    as a deprecated alias (legacy of the v0.149.0 OAS→MASC migration)
    and emits a one-time warning. *)

val window_sec : float
(** Rolling window duration in seconds.  Default 300.0 (5 min). *)

val cooldown_threshold : int
(** Consecutive failures before cooldown activates.  Default 3. *)

val cooldown_sec : float
(** Cooldown duration in seconds.  Default 60.0. *)

val hard_quota_cooldown_sec : float
(** Cooldown duration applied immediately on a hard-quota-classified error
    (balance depleted, monthly quota reached, resource exhausted).  Unlike
    {!cooldown_sec}, no threshold is required — one hard-quota event is
    enough.  Default 3600.0 (1h).

    Env: [MASC_CASCADE_HARD_QUOTA_COOLDOWN_SEC] (with deprecated
    [OAS_CASCADE_HARD_QUOTA_COOLDOWN_SEC] alias).

    @since 0.161.0 *)

val terminal_failure_cooldown_sec : float
(** Cooldown duration applied immediately on a terminal structural
    provider/adapter failure, such as a Kimi CLI resumable-session conflict.
    Unlike {!cooldown_sec}, no threshold is required.  Default 3600.0 (1h).

    Env: [MASC_CASCADE_TERMINAL_FAILURE_COOLDOWN_SEC] (with deprecated
    [OAS_CASCADE_TERMINAL_FAILURE_COOLDOWN_SEC] alias). *)

val soft_rate_limit_cooldown_sec : float
(** Default cooldown applied immediately on a transient HTTP 429 (soft
    rate-limit) when no Retry-After hint is available.  Distinct from
    {!cooldown_sec} because a single 429 should already deprioritize the
    provider for the remainder of the current cascade cycle — the
    [cooldown_threshold] count-to-three semantics are wrong for transient
    rate limits.  Default 10.0 (10s).

    Env: [MASC_CASCADE_SOFT_RATE_LIMIT_COOLDOWN_SEC]. *)

val soft_rate_limit_max_clamp_sec : float
(** Upper clamp for caller-supplied [retry_after_s] when recording a soft
    rate-limit event.  Providers occasionally return Retry-After values
    measured in minutes or hours; honoring those literally would silently
    promote a transient 429 into a long blackout.  Anything that exceeds
    this clamp should be classified as {!record_hard_quota} by the
    caller, not as a soft rate-limit.  Default 120.0 (2 min).

    Env: [MASC_CASCADE_SOFT_RATE_LIMIT_MAX_CLAMP_SEC]. *)

val latency_ring_size : int
(** Number of recent successful-call latencies retained per provider for
    percentile observation.  The ring buffer is per-provider; older
    samples are silently overwritten as new successes arrive.

    A small ring is intentional — strategy decisions only need a
    "recent" sense of how fast the provider has been responding, not a
    full distribution.  100 samples cover ~5–15 minutes of activity for
    a busy provider while staying small enough to sort cheaply on every
    [provider_info] read.

    Default 100, env [MASC_CASCADE_LATENCY_RING_SIZE].  Values [<= 0]
    disable latency tracking entirely (the ring is treated as empty and
    [p50_latency_ms] / [p95_latency_ms] always return [None]). *)


(** Opaque health tracker state. *)
type t

(** Create a new empty tracker. *)
val create : unit -> t

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
  ?error_kind:string ->
  ?error_reason:string ->
  unit ->
  unit

(** Record a provider call where the response arrived but was rejected
    by the cascade's [accept] predicate (e.g. empty body, schema gate).

    Behaves like {!record_failure} for cooldown / weight purposes — a
    provider whose outputs are consistently unusable should be skipped —
    but is counted separately in [provider_info.rejected_in_window] so
    the dashboard can distinguish "provider down" from "provider returns
    garbage".

    Prior to 0.160.0 this path called {!record_success} (the response
    technically arrived), which silently masked gate drift: a provider
    could rank 100% healthy while every call fell through to the next
    cascade tier.

    See {!record_failure} for [error_kind] / [error_reason] semantics.

    @since 0.160.0 *)
val record_rejected :
  t ->
  provider_key:string ->
  ?error_kind:string ->
  ?error_reason:string ->
  unit ->
  unit

(** Record a provider call that failed with a hard-quota error (balance
    depleted, monthly quota reached, resource exhausted — classified
    upstream via [Llm_provider.Retry.is_hard_quota]).

    Unlike {!record_failure}, this triggers an immediate long cooldown
    ({!hard_quota_cooldown_sec}, default 1h) with no threshold — a
    provider whose account is out of credit will not recover within the
    60s [cooldown_sec] window, and weighted_random re-selection just
    wastes cascade turns.

    Preserves an already-longer cooldown if one exists (no regression).
    Counts toward [consecutive_failures] for dashboard continuity and
    toward [events_in_window] in {!provider_info}.

    See {!record_failure} for [error_kind] / [error_reason] semantics.

    @since 0.161.0 *)
val record_hard_quota :
  t ->
  provider_key:string ->
  ?error_kind:string ->
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
  ?error_kind:string ->
  ?error_reason:string ->
  unit ->
  unit

(** Record a transient HTTP 429 (rate-limit) response.

    Unlike {!record_failure}, a single soft rate-limit triggers an
    immediate short cooldown so the cascade can fall over to the next
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
  ?error_kind:string ->
  ?error_reason:string ->
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

(** Compute effective weight for weighted cascade selection.

    [effective_weight = config_weight * success_rate]

    Returns 0 for providers in cooldown.
    Returns full [config_weight] for unknown providers. *)
val effective_weight : t -> provider_key:string -> config_weight:int -> int

(** Human-readable summary for debugging/telemetry. *)
val provider_summary : t -> provider_key:string -> string

(** Structured summary for telemetry/dashboard consumption.

    @since 0.139.0 *)
type provider_info = {
  provider_key : string;
  success_rate : float;               (** 0.0 to 1.0, 1.0 if unknown *)
  consecutive_failures : int;
  in_cooldown : bool;
  cooldown_expires_at : float option; (** Unix timestamp, Some iff [in_cooldown] *)
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
}

(** Structured info for a single provider. Returns [None] if untracked.
    @since 0.139.0 *)
val provider_info : t -> provider_key:string -> provider_info option

(** Snapshot of all tracked providers.
    Useful for dashboards and telemetry endpoints.
    @since 0.139.0 *)
val all_providers : t -> provider_info list

(** Outcome variant exposed for {!recent_outcome_count} window queries.
    Mirrors the internal classification — kept abstract elsewhere to
    keep the recording surface narrow.

    @since 0.183.0 *)
type outcome_kind =
  | Outcome_success
  | Outcome_failure
  | Outcome_rejected
  | Outcome_hard_quota
  | Outcome_terminal_failure
  | Outcome_soft_rate_limited

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

(** Global singleton tracker shared across all cascade calls.
    Use this for production; use {!create} for isolated tests. *)
val global : t
