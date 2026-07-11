(** Board_sort — single source of truth for board post ranking formulas.

    Extracted to eliminate the Hot-sort duplication between
    {!Board_core.list_posts} (cached default sort) and
    {!Board_dispatch.sort_posts_in_memory} (HTTP/MCP sort path). Editing
    one site no longer silently drifts the other.

    Ranking semantics:
    - Hot ranks on a time-decayed log-vote score ({!hot_score}), DESC,
      with created_at DESC tiebreak. Formula and constants: see
      {!hot_score}.
    - Best ranks on the Wilson score interval lower bound
      ({!wilson_lower_bound}) over (votes_up, votes_down) — the
      confidence-adjusted upvote ratio, so a post with few votes does
      not outrank one with many votes at the same ratio. See
      {!wilson_lower_bound}.
    - Recent/Updated/Discussed remain simple field comparators owned by
      {!Board_dispatch.sort_posts_in_memory}; they need no shared
      formula.

    board-quality-wilson (item #58): replaced the former Trending sort
    (net vote / sqrt(age hours), no confidence weighting) with the
    decayed Hot below — Trending's only distinguishing feature (time
    decay) is now Hot's default behavior, so keeping both was two
    parallel projections of "recency-weighted votes". See
    [docs/spec/11-board.md] §5.

    @since board-karma-v2 (S2); reworked board-quality-wilson (#58) *)

(** Net peer vote: upvotes minus downvotes.

    Negative for downvote-heavy posts; this is the load-bearing ranking
    input. Named (not inlined) so every ranking formula reads the same
    definition. *)
let net_vote (p : Board_types.post) : int = p.votes_up - p.votes_down

(** Reddit "hot" epoch reference point (2005-12-08T07:46:43Z — Reddit's
    own reference implementation's epoch). [hot_score] only feeds
    relative comparisons, so any fixed epoch produces identical
    ordering; kept at the published value for traceability to the
    source formula below, not because the specific date matters. *)
let hot_epoch_seconds = 1_134_028_003.0

(** Seconds-per-decade-of-votes decay divisor from Reddit's published
    hot-ranking formula (reddit-archive/reddit
    r2/r2/lib/db/_sorts.pyx, function [hot]): every 45000 seconds
    (12.5 hours) of age costs a post the ranking equivalent of one
    order-of-magnitude change in net vote count ([log10]). *)
let hot_decay_seconds = 45_000.0

(** Hot ranking score for a single post: [sign(net) * log10(max(1,
    |net|)) + (created_at - epoch) / hot_decay_seconds] — Reddit's
    "hot" formula (reddit-archive/reddit r2/r2/lib/db/_sorts.pyx,
    function [hot]). The log term makes vote-count differences matter
    less as they grow (10 vs 11 net votes barely moves the score; 1 vs
    11 does); the linear time term lets newer posts at a lower vote
    count still overtake older heavily-voted ones, which is the decay
    the old Trending formula had and raw-net-vote Hot did not. *)
let hot_score (p : Board_types.post) : float =
  let net = Stdlib.float_of_int (net_vote p) in
  let sign = if net > 0.0 then 1.0 else if net < 0.0 then -1.0 else 0.0 in
  let order = Stdlib.log10 (Stdlib.Float.max 1.0 (Stdlib.Float.abs net)) in
  (sign *. order) +. ((p.created_at -. hot_epoch_seconds) /. hot_decay_seconds)

(** Hot ordering comparator.

    [compare a b]: {!hot_score} DESC, then created_at DESC (newer
    first). Suitable as the argument to [List.sort]. *)
let hot_compare (a : Board_types.post) (b : Board_types.post) : int =
  let cmp = Stdlib.Float.compare (hot_score b) (hot_score a) in
  if cmp <> 0 then cmp
  else Stdlib.Float.compare b.created_at a.created_at

(** z-value for a 95% confidence normal approximation to the Binomial
    proportion, per Evan Miller, "How Not To Sort By Average Rating"
    (2009,
    https://www.evanmiller.org/how-not-to-sort-by-average-rating.html) —
    the derivation Reddit's own "best" sort
    (reddit-archive/reddit r2/r2/lib/db/_sorts.pyx, function
    [_confidence]) implements verbatim, including this constant. *)
let wilson_z = 1.96

(** Wilson score interval lower bound for a Bernoulli proportion
    estimated from [ups] successes out of [ups + downs] trials.

    Formula: [(p̂ + z²/2n - z * sqrt((p̂(1-p̂) + z²/4n) / n)) / (1 +
    z²/n)] where [p̂ = ups / n], [n = ups + downs], [z = wilson_z].
    This is the closed-form lower bound derived in Evan Miller's "How
    Not To Sort By Average Rating" (see {!wilson_z}); it is the reason
    a post with 1 upvote / 0 downvotes does not outrank one with 99
    upvotes / 1 downvote — the raw ratio (1.0 vs 0.99) says the
    opposite, but the interval width at n=1 makes the bound near 0.

    Returns [0.0] when [ups + downs = 0] (no evidence). Callers that
    need to distinguish "no votes cast" from "confidently rated near
    zero" must check [ups + downs = 0] themselves — this function
    only computes the bound. *)
let wilson_lower_bound ~ups ~downs : float =
  let n = Stdlib.float_of_int (ups + downs) in
  if n <= 0.0 then 0.0
  else
    let phat = Stdlib.float_of_int ups /. n in
    let z2 = wilson_z *. wilson_z in
    ((phat +. (z2 /. (2.0 *. n)))
     -. (wilson_z *. Stdlib.sqrt (((phat *. (1.0 -. phat)) +. (z2 /. (4.0 *. n))) /. n)))
    /. (1.0 +. (z2 /. n))

(** Best ordering comparator: {!wilson_lower_bound} over a post's own
    (votes_up, votes_down) DESC, then created_at DESC. *)
let best_compare (a : Board_types.post) (b : Board_types.post) : int =
  let score (p : Board_types.post) =
    wilson_lower_bound ~ups:p.votes_up ~downs:p.votes_down
  in
  let cmp = Stdlib.Float.compare (score b) (score a) in
  if cmp <> 0 then cmp
  else Stdlib.Float.compare b.created_at a.created_at
