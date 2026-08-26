(** Messages typed while a turn was running, waiting for the next one.

    Dispatch is serialized on one in-flight request, so a second Enter used to
    be answered with "Keeper message already in progress" and the text was
    gone. Holding it is what an operator means by pressing Enter twice, and
    what every other agent console does.

    Order is submission order and nothing reorders it: two lines typed as one
    thought arrive as one thought.

    {2 Why whole requests}

    A queued line used to be a keeper name and some text, with the request
    built later at dispatch. Two things followed from that, and both were
    wrong. Staged attachments were taken at dispatch, so an image attached
    while a line waited went out with *that* line rather than the one it was
    attached to. And a waiting line had no request_id, which is the key the
    transcript uses to recognise a row it already holds -- so it could not be
    shown in the conversation until it was sent, and the operator's own
    message was invisible for as long as it waited.

    The request is built when the operator presses Enter. What waits is what
    will be sent, identity and attachments included. *)

module Chat = Masc_tui_keeper_chat_projection

type t

val empty : t
val is_empty : t -> bool
val length : t -> int

val waiting : t -> Chat.request list
(** Oldest first -- what the pane draws. *)

val cap : int
(** How many lines may wait. A turn that never settles would otherwise grow
    this without limit. *)

val push : t -> Chat.request -> (t * int, string) result
(** Append one request. [Ok (queue, waiting)] carries how many are now waiting,
    so the caller can say it. [Error] at {!cap}: refused and named, rather than
    dropping the oldest and leaving the operator to notice a line went
    missing. *)

val take_first_sendable : t -> sendable:(string -> bool) -> (Chat.request * t) option
(** Take the oldest request whose keeper [sendable] accepts, keeping the rest
    in order.

    Not [pop]: a line waits because its own keeper had a turn running, and
    keepers run turns independently. Taking strictly from the front stalls
    every line behind one whose keeper is still busy -- and nothing will ever
    free them, because the keeper they are addressed to is idle and so has no
    settle coming to drain them. *)

val take_newest : t -> (Chat.request * t) option
(** Take the newest waiting request. The newest is the one an operator just
    typed and the one a mis-send hits: cancel drops it, and pulling it back
    into the composer is the edit. Nothing was dispatched, so both are local
    decisions with nothing to undo on the server. [None] when nothing waits. *)

val drop_for_keeper : t -> keeper_name:string -> t
(** Forget what was waiting for one keeper. Used when that keeper is gone: a
    line cannot be delivered to a keeper that is no longer registered, and
    holding it forever would make the count say work is pending that never
    moves. *)

val holds : t -> request_id:string -> bool
(** Whether this request is still waiting. The conversation shows a queued
    message from the moment it is typed, and this is how a row learns whether
    it is still waiting or has since gone out -- one place holds that fact, so
    the row and the queue cannot disagree about it. *)
