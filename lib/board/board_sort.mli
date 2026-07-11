(** Board_sort — single source of truth for board post ranking formulas.

    See {!Board_sort} for the rationale (Hot/Best formulas, why
    Trending was folded into the new decayed Hot). *)

val net_vote : Board_types.post -> int
(** [net_vote p] is [p.votes_up - p.votes_down]. Negative for
    downvote-heavy posts. *)

val hot_epoch_seconds : float
(** Fixed reference point for {!hot_score}'s decay term. Any fixed
    epoch yields identical ordering; see {!Board_sort} for why this
    specific value was chosen (traceability, not correctness). *)

val hot_decay_seconds : float
(** Seconds of age equivalent to one order-of-magnitude change in net
    vote count in {!hot_score}. See {!Board_sort} for the source
    formula. *)

val hot_score : Board_types.post -> float
(** Time-decayed log-vote hot ranking score. See {!Board_sort} for the
    formula and citation. *)

val hot_compare : Board_types.post -> Board_types.post -> int
(** Hot ordering comparator: {!hot_score} DESC, then created_at DESC. *)

val wilson_z : float
(** z-value for the 95% confidence Wilson score interval used by
    {!wilson_lower_bound}. See {!Board_sort} for citation. *)

val wilson_lower_bound : ups:int -> downs:int -> float
(** Wilson score interval lower bound over [ups] successes in
    [ups + downs] trials. [0.0] when [ups + downs = 0] — see
    {!Board_sort} for the full formula and citation. *)

val best_compare : Board_types.post -> Board_types.post -> int
(** Best ordering comparator: {!wilson_lower_bound} over
    (votes_up, votes_down) DESC, then created_at DESC. *)
