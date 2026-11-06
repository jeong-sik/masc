(** Chat requests queued behind a Keeper's running turn.

    A chat request, such as a delegation from another Keeper, starts after the
    turn that is running ends. A turn that runs for hours keeps it waiting for
    hours, and the running turn cannot see it: the owner's queue of chat
    operations is not in its prompt
    (docs/rfc/RFC-backlog-never-preempts-a-running-turn.md, 1.7). This module
    says how many are queued and nothing else. It starts nothing, ends nothing
    and carries no message text, so what to do about the count stays with the
    Keeper. *)

type waiting =
  | Not_waiting
      (** Nothing is queued, or every queued operation waits for something
          other than this turn: a gate resolution or a retry time. *)
  | Waiting of { queued : int }
      (** [queued] operations are queued and at least one of them starts once
          the running turn ends. [queued] also counts the ones that wait for
          something else. *)

val waiting_of_projection :
  store_unavailable:bool ->
  queued_count:int ->
  has_claimable_queued:bool ->
  (waiting, string) result
(** The owner's operation projection as a value that cannot disagree with
    itself. A projection whose store is unavailable keeps the counts of the
    last good read, so it is an [Error], not a count. A negative count, or a
    claimable operation with a zero count, is an [Error] that names it. *)

val render : waiting -> string option
(** The block text, or [None] for {!Not_waiting}. It states how many requests
    are queued and that they start after this turn ends. *)

(** What one run has already told the model. A count counts as told only once
    the model has answered the request that carried it, so a request that
    failed before the model saw the block tells it again on the next round. *)
type tracker

val create_tracker : unit -> tracker

val next : tracker -> waiting -> waiting option
(** The state to tell now, or [None] when the model already knows a count at
    least as high. A lower count is recorded, so a later rise is news again.
    The state it returns waits for {!confirm}; asking again before then
    returns it again. *)

val confirm : tracker -> unit
(** The model answered the request that carried the last {!next}. *)

val block :
  tracker ->
  read:(unit -> (waiting, string) result) ->
  on_unavailable:(string -> unit) ->
  string option
(** The text a round carries: [read] gives the queue as it stands, {!next}
    decides whether it is news and {!render} writes it. A queue that cannot be
    read gives [None] and calls [on_unavailable] with the reason; the tracker
    is not touched, so the next round tells what this one could not. *)
