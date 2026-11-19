(** Closing a head's open messages with one save before a line names them
    (RFC librarian-call-only-proposes §5.2).

    A line names closed messages only. Two steps close the head's open
    messages before they write: the process start step, when the log's last
    [Opened] is open, and the function a product path shrinks a head through
    ({!Keeper_turn_log_reset}). They differ only in what a failed save
    means, and that is theirs to decide. *)

type not_closed =
  | Head_unread of Keeper_checkpoint_store_decode.checkpoint_load_error
  | History_unread of Keeper_checkpoint_store.Saved_history.ref_error
  | Save_not_installed of Keeper_checkpoint_store.checkpoint_cas_error

type t =
  | Nothing_open
  (** The head holds no open message, or it is a history of a format this
      build supersedes. The next turn starts fresh and does not continue such
      a history, so none of its messages is open for anyone; the turn log's
      head read counts it as empty too ({!Keeper_turn_log_head}). *)
  | Closed_open of { messages : int }
  | Not_closed of not_closed

(** The save a turn's end makes: the messages are the ones the head already
    holds, and [Turn_closes] writes the open ones as one bundle. The head is
    read first because it is small; the whole history is read only when it
    holds open messages. *)
val close_open : Keeper_turn_log_recorder.place -> t

val not_closed_to_string : not_closed -> string
