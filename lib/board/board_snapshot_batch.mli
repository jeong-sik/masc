(** Immutable Board snapshot selection, captured work and write outcomes.
    Callers retain ownership of the store, locks and persistence effects. *)

type kind = Posts | Comments | Votes | Reactions

type selection
(** Selected kinds, each appearing once in Posts, Comments, Votes, Reactions
    order, with their deletion or independent-flush purpose. *)

val for_delete : selection
(** Select every kind for ordered deletion work. The first returned write error
    stops later sources. Retried deletions use this selection again, including
    unreadable sources whose writers must refuse rather than omit their work. *)

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
  | Comments_payload of Board_core_persist.comments_snapshot
  | Votes_payload of string
  | Reactions_payload of string
val kind_of_payload : payload -> kind

type t
(** Captured contents. Selected empty strings remain work; they are distinct
    from omitted snapshots. *)

val capture : selection ->
  posts:(unit -> Board_core_persist.posts_snapshot) ->
  comments:(unit -> Board_core_persist.comments_snapshot) ->
  votes:(unit -> string) -> reactions:(unit -> string) -> t
(** Invoke the selected producer once for each selected kind, in selection order. The caller
    holds the state lock while the producer observes the store and updates row caches. *)

type outcome
(** Every selected obligation in batch order, distinguishing attempted writes
    from pending work after a failed deletion prerequisite or reserved settlement. *)

val persist :
  t ->
  write:(payload -> (unit, Board_types.board_error) result) ->
  outcome
(** Invoke selected [write] calls in batch order, including empty contents.
    Deletion batches stop on the first returned error and retain later work as
    pending. Independent flush batches continue after returned errors.
    The first private known-settlement carrier stops further write calls for
    either purpose; its result and original exception are
    retained until {!finish_settlement}, and every remaining selected kind stays
    pending for retry. Other exceptions propagate to the caller.

    The caller holds the protected persistence lock, outside the state lock,
    and retains it through retry marking. This module neither acquires locks
    nor clears dirty state. *)

val finish_settlement : outcome -> unit
(** After retry marking, propagate the first deferred reserved settlement with
    its original backtrace, through the persistence lock's private carrier. *)

type retry = Retry_posts | Retry_comments

val retry_for_kind : kind -> retry
(** Posts, votes and reactions retry through posts; comments retry themselves.
    Pending auxiliary work can therefore make a separate retry flush rewrite
    current posts through exact CAS, even when their earlier write succeeded. *)

val retries : outcome -> retry list
(** Failed attempted and unattempted pending obligations, deduplicated with posts
    before comments. A successful attempted write alone adds no retry obligation. *)

val errors : outcome -> Board_types.board_error list
(** Actual attempted write errors in batch order. Pending work has no fabricated
    error result. *)
