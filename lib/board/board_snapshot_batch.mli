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

type payload =
  | Posts_payload of Board_core_persist.posts_snapshot
  | Comments_payload of string
  | Votes_payload of string
  | Reactions_payload of string
val kind_of_payload : payload -> kind

type t
(** Captured contents. Selected empty strings remain work; they are distinct
    from omitted snapshots. *)

val capture : selection ->
  posts:(unit -> Board_core_persist.posts_snapshot) ->
  comments:(unit -> string) -> votes:(unit -> string) -> reactions:(unit -> string) -> t
(** Invoke the selected producer once for each selected kind, in selection order. The caller
    holds the state lock while the producer observes the store and updates row caches. *)

type outcome
(** A result for every attempted write, in the same order as the batch, and any
    deferred reserved exception from known posts settlement. *)

val persist :
  t ->
  write:(payload -> (unit, Board_types.board_error) result) ->
  outcome
(** Invoke every selected [write] in batch order, including empty contents.
    Returned errors do not stop later writes. The private known-settlement
    carrier is deferred until {!finish_settlement}, preserving later captured
    obligations. Other exceptions propagate to the caller.

    The caller holds the protected persistence lock, outside the state lock,
    and retains it through retry marking. This module neither acquires locks
    nor clears dirty state. *)

val finish_settlement : outcome -> unit
(** After retry marking, propagate the first deferred reserved settlement with
    its original backtrace, through the persistence lock's private carrier. *)

type retry = Retry_posts | Retry_comments

val retry_for_kind : kind -> retry
(** Posts, votes and reactions retry through posts; comments retry themselves. *)

val retries : outcome -> retry list
(** Failed write obligations, deduplicated with posts before comments. *)

val errors : outcome -> Board_types.board_error list
(** All returned write errors in batch order. *)
