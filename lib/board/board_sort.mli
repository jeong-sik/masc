(** Board_sort — single source of truth for board post ranking formulas.

    See {!Board_sort} for the rationale (Hot-sort deduplication, Trending
    net-vote-only semantics). *)

val net_vote : Board_types.post -> int
(** [net_vote p] is [p.votes_up - p.votes_down]. Negative for
    downvote-heavy posts. *)

val hot_compare : Board_types.post -> Board_types.post -> int
(** Hot ordering comparator: net vote DESC, then created_at DESC. *)

val trending_score : now:float -> Board_types.post -> float
(** Trending score: net vote / sqrt(age in hours), age floored at 1h. *)

val trending_compare : now:float -> Board_types.post -> Board_types.post -> int
(** Trending ordering comparator: trending score DESC. *)
