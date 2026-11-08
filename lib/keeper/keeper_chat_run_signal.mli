(** What an adapter that waits for the end of one chat run reads from the run's
    events. It needs four things: the reply details, the end of the run, an
    error, and the bus closing. Every other event is progress it ignores. *)

type t =
  | Closed  (** The publisher closed the bus; no event follows. *)
  | Reply of Keeper_chat_events.reply_details
  | Finished  (** The run ended; the adapter delivers what it collected. *)
  | Failed of string
  | Progress

val of_event : Keeper_chat_events.keeper_chat_event -> t
(** One arm per event variant and no wildcard: a new variant does not compile
    until it is classified here. *)

val is_terminal : Keeper_chat_events.keeper_chat_event -> bool
(** [true] for the event that ends a run, [Finished] or [Failed _]. A reader
    that holds events outside the bus, such as the journal or the Dashboard
    projection, asks the same question here. *)

val read : Keeper_chat_events.t -> t
(** The next event of the bus, classified. Blocks like
    {!Keeper_chat_events.subscribe}. *)

val visible_text : Keeper_chat_events.reply_details -> string option
(** The text a plain-text channel sends for a reply: the reply of a
    [Visible_reply] turn when it is not blank. Every other outcome has no text
    to send, because the turn spoke somewhere else or said nothing. *)
