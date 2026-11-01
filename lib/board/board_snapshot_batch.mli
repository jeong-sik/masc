(** Immutable Board snapshot selection, captured work and write outcomes.
    Callers retain ownership of the store, locks and persistence effects. *)

type kind = Posts | Comments | Votes | Reactions

type selection
(** Selected kinds, each appearing once in Posts, Comments, Votes, Reactions
    order. *)

val for_delete : selection
(** Select every kind after the caller has verified all sources are readable. *)

val for_flush :
  dirty_posts:bool ->
  dirty_comments:bool ->
  votes_readable:bool ->
  reactions_readable:bool ->
  selection
(** Select each primary snapshot from its own dirty flag. Select readable votes
    and reactions when either primary snapshot is dirty. Primary load failures
    do not omit work: their writers refuse it, preserving a failed result for
    retry classification. *)

type t
(** Captured contents. Selected empty strings remain work; they are distinct
    from omitted snapshots. *)

val capture : selection -> read:(kind -> string) -> t
(** Invoke [read] once for each selected kind, in selection order. The caller
    holds the state lock while [read] observes the store and updates row caches. *)

type 'error outcome
(** A result for every attempted write, in the same order as the batch. *)

val persist :
  t ->
  write:(kind -> string -> (unit, 'error) result) ->
  'error outcome
(** Invoke every selected [write] in batch order, including empty contents.
    Returned errors do not stop later writes. Exceptions, including cancellation,
    propagate to the caller.

    The caller holds the protected persistence lock, outside the state lock,
    and retains it through retry marking. This module neither acquires locks
    nor clears dirty state. *)

type retry = Retry_posts | Retry_comments

val retry_for_kind : kind -> retry
(** Posts, votes and reactions retry through posts; comments retry themselves. *)

val retries : 'error outcome -> retry list
(** Failed write obligations, deduplicated with posts before comments. *)

val errors : 'error outcome -> 'error list
(** All returned write errors in batch order. *)
