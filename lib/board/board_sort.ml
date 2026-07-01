(** Board_sort — single source of truth for board post ranking formulas.

    Extracted to eliminate the Hot-sort duplication between
    {!Board_core.list_posts} (cached default sort) and
    {!Board_dispatch.sort_posts_in_memory} (HTTP/MCP sort path). Editing
    one site no longer silently drifts the other.

    Ranking semantics:
    - Hot ranks on net peer vote ({!net_vote} = votes_up - votes_down),
      DESC, with created_at DESC tiebreak.
    - Trending ranks on net peer vote only, decayed by sqrt(age in hours).
      Reply count is a separate engagement signal and is NOT summed into
      the ranking score. The previous formula ((net + reply_count * 2) /
      sqrt(age)) boosted downvote-heavy controversial posts above cleanly
      upvoted posts — e.g. net -98 with 80 replies outranked net +40 with
      0 replies at the same age. See [docs/spec/11-board.md] §5 and the
      board-karma-v2 plan.

    @since board-karma-v2 (S2) *)

(** Net peer vote: upvotes minus downvotes.

    Negative for downvote-heavy posts; this is the load-bearing ranking
    input. Named (not inlined) so every ranking formula reads the same
    definition. *)
let net_vote (p : Board_types.post) : int = p.votes_up - p.votes_down

(** Hot ordering comparator.

    [compare a b]: net vote DESC, then created_at DESC (newer first).
    Suitable as the argument to [List.sort]. *)
let hot_compare (a : Board_types.post) (b : Board_types.post) : int =
  let cmp = Stdlib.Int.compare (net_vote b) (net_vote a) in
  if cmp <> 0 then cmp
  else Stdlib.Float.compare b.created_at a.created_at

(** Trending score for a single post: net vote / sqrt(age in hours).

    Age is floored at 1.0 hour so that sub-hour posts do not acquire a
    sub-1 divisor spike. [now] is the evaluation timestamp (wall clock). *)
let trending_score ~now (p : Board_types.post) : float =
  let age_hours =
    Stdlib.Float.max 1.0 ((now -. p.created_at) /. Masc_time_constants.hour)
  in
  Stdlib.Float.of_int (net_vote p) /. Stdlib.sqrt age_hours

(** Trending ordering comparator. [compare a b]: trending score DESC, then
    created_at DESC (newer first) — matches [hot_compare]'s tiebreak so
    posts with an identical score have a deterministic, not [List.sort]-
    implementation-dependent, order. *)
let trending_compare ~now (a : Board_types.post) (b : Board_types.post) : int =
  let cmp = Stdlib.Float.compare (trending_score ~now b) (trending_score ~now a) in
  if cmp <> 0 then cmp
  else Stdlib.Float.compare b.created_at a.created_at
