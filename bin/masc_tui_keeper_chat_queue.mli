(** Messages typed while a turn was running, waiting for the next one.

    Dispatch is serialized on one in-flight request, so a second Enter used to
    be answered with "Keeper message already in progress" and the text was
    gone. Holding it is what an operator means by pressing Enter twice, and
    what every other agent console does.

    Ordinary [Next] input keeps submission order. [Next_without_auto_priority]
    records a server control superseding an earlier priority request.
    [Run_next] retains a manual
    or automatic priority request until admission. An explicit
    [Steer_after_interrupt] records a steer and its requested priority. It
    does not prove the target was interrupted. [Steer_without_priority] keeps
    the steer after control supersedes priority and restores local order.

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
(** Local queue with a submission counter retained across extraction and removal. *)

type intent =
  | Next
  | Next_without_auto_priority
  | Run_next of { automatic : bool }
  | Steer_after_interrupt
  | Steer_without_priority

type source =
  | Request_message
  | Staged_fragments of string list
      (** Accepted input fragments in reverse order, joined by newlines.
          Materialized only when the original text is needed. *)

type item =
  { request : Chat.request
  ; source : source
      (** The accepted input before staging replaced part of it with a file
          reference. An explicit edit of that reference is new input. *)
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

val restore_unsent : t -> item -> t
(** Return an already admitted item whose first POST never began. It precedes
    input staged while its workspace probe was pending, retaining its payload,
    submission ordinal, intent and causal parent. An item whose priority was
    superseded returns to its Keeper's submission order. The admission cap
    cannot discard existing input.
    A request already held by the queue is left unchanged. *)

val mark_run_next : t -> request_id:string -> (t, string) result
(** Record explicit priority on an unsent item without moving its queue slot.
    A steer keeps its causal parent, even if its prior priority was cancelled. *)

val clear_run_next_for_keeper : t -> keeper_name:string -> t
(** Retire unsent run-next or steer priority after a superseding Keeper
    control, prevent automatic promotion, and restore that Keeper's local
    submission order without moving other Keepers' slots. *)

val prepare_for_admission : automatic:bool -> item -> item
(** Apply automatic priority only to an ordinary unsent item. An item whose
    prior priority was superseded by a control stays ordinary. *)

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

val local_order_editable : item -> bool
(** Whether the operator may move this item within its Keeper's line. A steer
    waiting for its interrupt and an item holding run-next priority keep their
    place ahead of the line. *)

val move_to_end : t -> keeper_name:string -> request_id:string -> (t, string) result
(** Move an ordinary unsent item behind the same Keeper's waiting items,
    retaining other Keepers' slots and the item's submission identity. A steer
    retains its causal precedence and cannot be moved. *)

val move_to_front : t -> keeper_name:string -> request_id:string -> (t, string) result
(** Move an ordinary unsent item ahead of the same Keeper's ordinary input.
    Steers remain ahead, and the ordinary dispatch admission rules still apply. *)

val source_text : item -> string
(** Materialize the accepted input. Joining staged input stores fragments
    without repeatedly copying earlier paste bytes. *)

val source_for_edit : item -> message:string -> source
(** Preserve the original source if the wire message is unchanged. *)

val source_for_join : item -> message:string -> source
(** Append accepted input to a prior item's source in constant time. *)

val source_for_staging : item -> message:string -> source
(** Preserve the accepted source when the wire message becomes a file reference. *)

val replace_request :
  ?source:source -> t -> request_id:string -> Chat.request -> (t, string) result
(** Edit a pending request in place while preserving intent, causal parent,
    submission sequence, submitted_at, and dispatch position. The replacement
    must retain the same request_id. Unless supplied, the source is the
    replacement request's message. *)

val replace_recalled_request :
  ?source:source -> t -> original:item -> Chat.request -> (t, string) result
(** Replace only the payload the editor recalled. Changes to queue priority
    are preserved; a changed or absent request or source is not overwritten. *)

val join_target : t -> keeper_name:string -> item option
(** The most recently submitted waiting next-turn line a newly typed line for
    this Keeper would join, or [None] when there is nothing to join. Reordering
    dispatch must not change which original submission receives a joined line.

    Only the last item in dispatch order can be joined. If that item is a
    steer or run-next, do not reach past it to an older ordinary input. The
    caller also decides whether a locally retained item may be edited. *)
