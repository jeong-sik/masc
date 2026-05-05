(** Admission router for the work-conserving keeper scheduler.

    Layer 2 of RFC-0026 §3.3.  Owns the per-turn decision: given a
    keeper, walk its persona-declared candidate list (PR-B) and find
    the first provider whose token bucket (PR-A) has capacity.  The
    decision itself is non-blocking — the call returns one of three
    discrete outcomes that the caller acts on.

    This module does NOT:

    - own the WFQ overflow queue (separate module, PR-C-2).
      [Wait] decisions hand off the keeper to the queue; this router
      does not enqueue itself.
    - mutate token buckets directly except via the
      [Keeper_provider_token_bucket.try_acquire] non-blocking call.
    - emit Prometheus metrics (a thin wrapper module owned by the
      observability layer composes this router with metric counters).

    Layered invariants (RFC-0026 §3.1):

      I2 (Work-Conserving): if any candidate above [min_tier] has
      tokens, [schedule] must return [Dispatch], not [Wait].

      I5 (Drift Observability): every [Dispatch] decision exposes
      [preferred_provider] and [actual_provider] (which may differ);
      callers log this pair to the dispatch counter. *)

(** {1 Decision type} *)

type surface_reason =
  | Min_tier_unsatisfiable
  (** No candidate at-or-above [min_tier] has any token AND the
      router has determined that even after a refill, no above-floor
      candidate would be eligible (e.g. capacity_exhausted across
      every above-floor provider).  Operator alert. *)
  | All_candidates_throttled
  (** Every candidate has tokens=0 right now, but at least one
      above-floor candidate has positive long-run rate.  The keeper
      should be enqueued in the WFQ overflow rather than escalated.
      Returned to the caller as part of [Wait], not [Surface] —
      [Surface] is reserved for cases where queueing won't help. *)

type drift_record = {
  preferred_provider : string;
  (** The persona's top-tier provider (head of candidate list). *)
  actual_provider : string;
  (** The provider whose bucket was actually consumed. *)
  tier : Keeper_admission_policy.tier;
  (** Tier of [actual_provider] in the persona's policy. *)
  reason : string;
  (** "preferred" if [preferred = actual], else short label like
      "fallback" or "survival_recovery".  Used as a Prometheus label
      and a board-comment line. *)
}

type decision =
  | Dispatch of {
      candidate : Keeper_admission_policy.candidate;
      drift : drift_record;
    }
  (** A token was acquired from [candidate.provider].  The caller
      proceeds with the LLM call and must release the bucket via
      [Keeper_provider_token_bucket.release] when work completes. *)
  | Wait
  (** No candidate above [min_tier] currently has tokens, but at
      least one has positive long-run rate.  The caller must enqueue
      the keeper in the WFQ overflow queue (PR-C-2). *)
  | Surface of surface_reason
  (** The router cannot find any usable provider.  The caller must
      surface an operator-visible event and skip this turn. *)

(** {1 Bucket lookup} *)

type bucket_lookup = string -> Keeper_provider_token_bucket.t option
(** [bucket_lookup provider] returns the bucket for [provider], or
    [None] if the provider is not configured.  Provided by the caller
    so this router does not depend on a global registry — easier to
    test, easier to A/B with multiple bucket sets. *)

(** {1 Decision API} *)

val schedule :
  policy:Keeper_admission_policy.t ->
  buckets:bucket_lookup ->
  decision
(** Make one admission decision for the keeper described by [policy].
    Walks [policy]'s candidate list in order; for each candidate at
    or above [min_tier], asks [buckets] for the bucket and tries to
    acquire one token.  First success returns [Dispatch].

    If every above-floor candidate is missing from [buckets] or
    refuses [try_acquire], returns [Wait] (or [Surface] when the
    above-floor set is empty entirely — that is misconfiguration,
    not throttling).

    Cost: O(N) where N = number of candidates in [policy].  No
    allocations beyond the [drift_record].  Pure with respect to
    persistent state — the only side effect is the bucket
    decrement inside [try_acquire], which is the contract this
    function exists to invoke.

    Thread-safety: re-entrant.  [try_acquire] is mutex-protected
    inside the bucket; [policy] is immutable; [buckets] is a function
    the caller is responsible for making safe. *)

(** {1 Drift classification helpers} *)

val classify_reason :
  preferred:string -> actual:string -> tier:Keeper_admission_policy.tier ->
  string
(** Stable string label for the dispatch event.  Mapping:

    {ul
      {- preferred = actual              -> ["preferred"]}
      {- preferred /= actual, tier=Acceptable -> ["fallback"]}
      {- preferred /= actual, tier=Survival   -> ["survival_recovery"]}
      {- preferred /= actual, tier=Preferred  -> ["secondary_preferred"]}}

    Pure helper; exposed so observability code can use the same
    classification without re-implementing it. *)
