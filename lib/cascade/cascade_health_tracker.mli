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

(** {1 Phase 1 trust_score parameters}

    Trust replaces the rolling [success_rate] as the {!effective_weight}
    driver.  Defaults are calibrated from a 4040-record analysis of
    keeper decisions.jsonl (2026-04-25): same-fingerprint failures
    recur within 5 minutes 96% of the time, top-5 fingerprints account
    for 74.5% of all errors, and max consecutive error streak observed
    was 108.  See module docstring for the full derivation.

    @since 0.175.0 *)

val trust_reward_on_success : float
(** Additive trust bump on every Success event.  Default 0.15.
    Env: [MASC_CASCADE_TRUST_REWARD_ON_SUCCESS]. *)

val trust_decay_transient : float
(** Multiplicative trust decay on a transient (one-shot) failure.
    Default 0.7.  Env: [MASC_CASCADE_TRUST_DECAY_TRANSIENT]. *)

val trust_decay_persistent : float
(** Multiplicative trust decay on a persistent failure (same fingerprint
    recurring within {!trust_persistent_window_sec}).  Default 0.15 —
    aggressively penalises rate-limit-style failures so the cascade
    rotates away within a few attempts.
    Env: [MASC_CASCADE_TRUST_DECAY_PERSISTENT]. *)

val trust_ceiling : float
(** Upper clamp for trust_score.  Default 2.0 — a healthy provider's
    [config_weight] can grow up to 2x via repeated successes.
    Env: [MASC_CASCADE_TRUST_CEILING]. *)

val trust_persistent_threshold : int
(** Number of same-fingerprint occurrences inside
    {!trust_persistent_window_sec} required to classify a failure
    persistent.  Default 2 (the very next recurrence triggers).
    Env: [MASC_CASCADE_TRUST_PERSISTENT_THRESHOLD]. *)

val trust_persistent_window_sec : float
(** Time window inside which same-fingerprint failures are coalesced
    for persistence classification.  Default 600.0 (10 min) — wider
    than the 5-min recurrence cluster but tighter than the 30-min
    plan default; chosen to catch rate-limit oscillations without
    misclassifying genuinely transient errors as persistent.
    Env: [MASC_CASCADE_TRUST_PERSISTENT_WINDOW_SEC]. *)

(** Opaque health tracker state. *)
type t

(** Create a new empty tracker. *)
val create : unit -> t

(** Record a successful provider call. Clears cooldown and resets
    consecutive failure counter. *)
val record_success : t -> provider_key:string -> unit

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

val trust_score : t -> provider_key:string -> float
(** Phase 1 trust_score in [0, {!trust_ceiling}].  Returns [1.0] for
    unknown providers (optimistic neutral).  Drives {!effective_weight}.
    @since 0.175.0 *)

(** Compute effective weight for weighted cascade selection.

    Phase 1: [effective_weight = max 1 (config_weight * clamp(trust, 0, ceiling))]

    Trust replaces [success_rate] as the weight driver — see module
    documentation for the calibration rationale.  Cooldown still wins
    (returns 0).  Unknown providers get full [config_weight] (trust=1.0). *)
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
  trust_score : float;
  (** Phase 1 reputation in [0, {!trust_ceiling}].  See {!trust_score}
      for semantics.  @since 0.175.0 *)
  same_fingerprint_count : int;
  (** Number of consecutive same-fingerprint failures inside the
      persistence window.  Reset on Success or different fingerprint.
      Surfaced for the dashboard to flag "stuck" providers before the
      cascade gives up on them.  @since 0.175.0 *)
}

(** Structured info for a single provider. Returns [None] if untracked.
    @since 0.139.0 *)
val provider_info : t -> provider_key:string -> provider_info option

(** Snapshot of all tracked providers.
    Useful for dashboards and telemetry endpoints.
    @since 0.139.0 *)
val all_providers : t -> provider_info list

(** Global singleton tracker shared across all cascade calls.
    Use this for production; use {!create} for isolated tests. *)
val global : t
