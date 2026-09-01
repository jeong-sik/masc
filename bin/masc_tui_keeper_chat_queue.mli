(** Messages typed while a turn was running, waiting for the next one.

    Dispatch is serialized on one in-flight request, so a second Enter used to
    be answered with "Keeper message already in progress" and the text was
    gone. Holding it is what an operator means by pressing Enter twice, and
    what every other agent console does.

    Ordinary [Next] input keeps submission order. An explicit
    [Steer_after_interrupt] is a different intent and precedes ordinary input
    for the same Keeper after the interrupted turn settles.

    {2 Why whole requests}

    A queued line used to be a keeper name and some text, with the request
    built later at dispatch. Two things followed from that, and both were
    wrong. Staged attachments were taken at dispatch, so an image attached
    while a line waited went out with *that* line rather than the one it was
    attached to. And a waiting line had no request_id, which is the key the
    transcript uses to recognise a row it already holds -- so it could not be
    shown in the conversation until it was sent, and the operator's own
    message had no stable identity or submission clock while it waited.

    The request is built when the operator presses Enter. What waits is what
    will be sent, identity, attachments, intent, and submission clock
    included. Pending items render in the separate NEXT lane rather than as
    transcript rows the model has not seen. *)

module Chat = Masc_tui_keeper_chat_projection

type t

type intent =
  | Next
  | Steer_after_interrupt

type item =
  { request : Chat.request
  ; submitted_at : float
  ; submission_seq : int
      (** Monotone local submission order. Dispatch priority can move a steer
          ahead of NEXT, so list position is not "newest input" authority. *)
  ; intent : intent
  ; causal_parent_request_id : string option
      (** Exact operation the steer was created to replace. [None] for an
          ordinary next-turn item. *)
  }
val empty : t
val is_empty : t -> bool
val length : t -> int
val length_for_keeper : t -> keeper_name:string -> int

val waiting : t -> item list
(** Dispatch order across all Keepers. *)

val waiting_for_keeper : t -> keeper_name:string -> item list
(** What one Keeper will receive, in dispatch order. A pending steer precedes
    ordinary next-turn input for that Keeper. *)

val cap : int
(** How many lines may wait. A turn that never settles would otherwise grow
    this without limit. *)

val push : t -> submitted_at:float -> Chat.request -> (t * int, string) result
(** Append one request. [Ok (queue, waiting)] carries how many are now waiting,
    for that request's Keeper, so the caller can say it. [Error] at {!cap}:
    refused and named, rather than dropping the oldest and leaving the
    operator to notice a line went missing. *)

val push_steer :
  t ->
  submitted_at:float ->
  causal_parent_request_id:string ->
  Chat.request ->
  (t * int, string) result
(** Queue an explicit replacement turn after the current turn is interrupted.
    At most one steer may wait for a Keeper. It dispatches before that
    Keeper's ordinary {!Next} items without reordering other Keepers' work. *)

val take_first_sendable : t -> sendable:(string -> bool) -> (item * t) option
(** Take the oldest request whose keeper [sendable] accepts, keeping the rest
    in order.

    Not [pop]: a line waits because its own keeper had a turn running, and
    keepers run turns independently. Taking strictly from the front stalls
    every line behind one whose keeper is still busy -- and nothing will ever
    free them, because the keeper they are addressed to is idle and so has no
    settle coming to drain them. *)

val take_newest : t -> (item * t) option
(** Take the newest waiting request. The newest is the one an operator just
    typed and the one a mis-send hits: cancel drops it, and pulling it back
    into the composer is the edit. Nothing was dispatched, so both are local
    decisions with nothing to undo on the server. [None] when nothing waits. *)

val take_newest_for_keeper : t -> keeper_name:string -> (item * t) option
(** The newest waiting item addressed to one Keeper, keeping every other
    Keeper's items in their original positions. Chat-pane cancel/edit uses
    this rather than acting on a workspace-global queue. *)

val drop_for_keeper : t -> keeper_name:string -> t
(** Forget what was waiting for one keeper. Used when that keeper is gone: a
    line cannot be delivered to a keeper that is no longer registered, and
    holding it forever would make the count say work is pending that never
    moves. *)

val take : t -> request_id:string -> (item * t) option
(** Take one named request out, keeping the rest in order. What an edit does
    to the line it replaces: the original leaves the queue in the same step
    the new one is built, so the two cannot both go out. [None] when the queue
    no longer holds it -- it went out while the operator was typing, and the
    edit becomes an ordinary new line. *)

val holds : t -> request_id:string -> bool
(** Whether this request is still waiting. Recall/edit and transcript
    projection read this exact request identity; neither infers pending state
    from a timestamp or rendered label. *)

val find : t -> request_id:string -> item option
(** Exact pending item, for intent-aware recall/edit behavior. *)

val replace_request :
  t -> request_id:string -> Chat.request -> (t, string) result
(** Edit a pending request in place while preserving intent, causal parent,
    submission sequence, submitted_at, and dispatch position. The replacement
    must retain the same request_id. *)
