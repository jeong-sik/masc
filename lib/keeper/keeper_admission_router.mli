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
      callers log this pair to the dispatch counter.

    Spec ↔ OCaml mapping (KeeperAdmissionLiveness.tla, iter 60 K-2.c):

      The TLA+ spec models five FSM phases for a single keeper
      [{Idle, Waiting, Dispatched, Working, Done}].  This OCaml
      module's [type decision] is the result of one [schedule] call,
      not an FSM — three discrete outcomes, not five.  The mapping
      is therefore "spec transition" ↔ "OCaml call result", spread
      across one [schedule] call and one paired [release_bucket]
      callback.  Reader who expects 5↔5 will be confused; the
      correspondence is:

        spec phase             | OCaml call / outcome
        -----------------------+---------------------------------------------
        Idle                   | (pre-state; no admission call yet)
        Idle -> Waiting        | caller invokes [schedule]
        Waiting -> Dispatched  | [schedule] returns [Dispatch _]
        Waiting -> Waiting     | [schedule] returns [Wait] (caller enqueues)
        Waiting -> Surface     | [schedule] returns [Surface _] (operator alert)
        Dispatched -> Working  | (caller's LLM call; opaque to this module)
        Working -> Done        | caller invokes [release_bucket]

      The five spec states are the caller's *external* FSM; this
      module is a stateless oracle that drives one transition per
      call.  K-2.a (HIGH, not yet applied) is the proposal to wrap
      the [Dispatch -> release_bucket] window in
      [Eio.Switch.on_release] so that a cancelled or panicking
      caller cannot leak the bucket in flight; without that, the
      spec's [RateRespect] invariant
      ([in_flight[p] <= Capacity[p]]) is only enforced on the
      happy path.

      Full audit and the four follow-up risks (K-2.a..d):
      [docs/tla-audit/kal-k1-admission-spec-ocaml-mapping-
      2026-05-12.md] (iter 56 #14895).

      Note: iter 56 audit memo line ~80 cited the OCaml outcome
      as a "4-variant policy enum"; that was speculative.  The
      verified count is three: [Dispatch | Wait | Surface].  A
      follow-up amendment of the audit memo will correct that line
      after iter 60 lands (gh issue tracked as K-2.c.1). *)

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

val schedule_peek :
  policy:Keeper_admission_policy.t ->
  buckets:bucket_lookup ->
  decision
(** Non-mutating variant of [schedule] for shadow-mode observation
    (RFC-0026 PR-E-1.6).  Returns the decision [schedule] would have
    produced without consuming a token.

    Differs from [schedule] in exactly one place: instead of
    [Keeper_provider_token_bucket.try_acquire] it queries
    [Keeper_provider_token_bucket.tokens_available] and treats
    [>= 1.0] as "would dispatch".

    Side effect: [tokens_available] performs a lazy refill (updates
    the bucket's [last_refill_at] timestamp) but does not consume a
    token.  This matches what a live call would observe.

    Use case: shadow-mode counter emission while
    [MASC_ADMISSION_USE_NEW] is off, so we can read the would-be
    decision distribution without affecting live admission. *)

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
