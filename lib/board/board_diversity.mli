(** Board_diversity — echo-chamber reduction via diversity-aware reranking.

    After sorting posts by their primary score (Hot/Trending), this module
    detects author overrepresentation in the top-N window and boosts posts
    from underrepresented authors.

    Operates entirely at the query layer — no schema changes, no new
    persistence fields, no migration.  The diversity bonus is ephemeral
    and computed on each [list_posts] call. *)

val rerank_for_diversity :
  posts:Board_types.post list ->
  sort_by:Board_dispatch.sort_order ->
  Board_types.post list
(** [rerank_for_diversity ~posts ~sort_by] reorders [posts] to improve
    author diversity in the top results.

    - Examines the top 10 posts, counts author frequency.
    - Finds "dead zones": runs of 3+ consecutive posts by the same author.
    - Lifts the most underrepresented-author post(s) into those zones.
    - No-op for [Recent], [Updated], [Discussed] sort modes. *)