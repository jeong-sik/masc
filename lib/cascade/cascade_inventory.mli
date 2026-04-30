(** Fleet-wide provider inventory for cross-cascade promotion.

    When a single cascade exhausts (every candidate cooled down,
    rate-limited, or failed), the keeper today gets [Cascade_exhausted]
    propagated upward and the turn fails — even when other cascades the
    process knows about have healthy, fast-responding providers idle.

    This module exposes a small fleet-aware selector that the cascade
    runtime can consult as a *one-shot* fallback when the primary
    cascade has nothing left to try.  It is read-only: it does not
    record outcomes, modify health state, or schedule anything.  The
    caller is responsible for actually running the chosen provider and
    feeding the result back through the normal {!Cascade_health_tracker}
    record_* path.

    The selector intentionally surfaces only one provider — picking
    "the next-best alternative across the fleet" is a different problem
    from "rank a list" and a single result is enough for one extra
    cascade attempt.  Repeated cross-cascade promotion within a single
    turn would defeat the cooldown semantics; that loop guard lives in
    the caller, not here.

    @since 0.182.0 (PR4 of cascade resilience track) *)

(** Score formula:
    [score = success_rate × latency_score × is_not_in_cooldown]

    - 0.0 when the provider is in cooldown.
    - 0.0 when the provider's [model_id] appears in the [exclude] list.
    - 0.0 when [keeper_assignable = false] for the cascade the provider
      came from (caller must filter externally — see
      {!score_provider}'s [keeper_assignable] flag).
    - Otherwise [success_rate × latency_score], both [0.0–1.0].

    Both [success_rate] and [latency_score] default to [1.0] for
    providers with no recorded events / latency samples — matches the
    optimistic-default convention used throughout the tracker.

    Returns a [float] in [0.0, 1.0].  Higher is better.  [0.0] means
    "do not select"; the caller must treat it as a hard exclusion, not
    a low-priority option, because [0.0 × anything] could otherwise
    re-emerge after rebalancing. *)
val score_provider :
  Cascade_health_tracker.t ->
  exclude:string list ->
  keeper_assignable:bool ->
  Llm_provider.Provider_config.t ->
  float

(** A provider scored against a snapshot of fleet state. *)
type scored_provider = {
  cascade_name : Keeper_cascade_profile.runtime_name;
  provider : Llm_provider.Provider_config.t;
  score : float;
}

(** [best_runner_among ~health ~exclude candidates] picks the
    highest-scoring entry from [candidates] whose score is strictly
    positive.  Returns [None] when every entry was filtered out
    (cooldown, in-exclude, or non-keeper-assignable cascade).

    Ties are broken by input order — the first candidate to reach the
    max wins.  This makes the choice deterministic given a stable input
    list and is enough for tests; production callers receive their
    [candidates] from {!Cascade_catalog_runtime} which has its own
    enumeration order.

    [exclude] is the list of [provider.model_id]s to skip — typically
    populated with the model IDs from the cascade that just exhausted,
    so cross-cascade promotion never re-elects a provider that already
    failed in the current turn. *)
val best_runner_among :
  health:Cascade_health_tracker.t ->
  exclude:string list ->
  scored_provider list ->
  scored_provider option
