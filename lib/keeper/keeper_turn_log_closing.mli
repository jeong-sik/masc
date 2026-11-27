(** Closing a head's open messages with one save before a line names them
    (RFC librarian-call-only-proposes §5.2).

    A line names closed messages only. Three steps close the head's open
    messages before they write: the end of a turn that saved in its middle
    and made no closing save ({!Keeper_turn_log_turn}), the process start
    step, when the log's last [Opened] is open, and the function a product
    path shrinks a head through ({!Keeper_turn_log_reset}). They differ only
    in what a failed save means, and that is theirs to decide. *)

type not_closed =
  | Head_unread of Keeper_checkpoint_store_decode.checkpoint_load_error
  | Open_turn_unread of Agent_core.Checkpoint_objects.load_error
  (** An open message's object is missing, unreadable or not the bytes its
      digest names. *)
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
    holds, and the open ones become one bundle, as a [Turn_closes] save
    writes them ({!Agent_core.Checkpoint_objects.close_open_turn}). Only the
    head and the open messages' objects are read; the closed history is
    neither read nor decoded, so the cost follows the open turn. The head is
    installed only while the canonical still holds the head that was read. *)
val close_open : Keeper_turn_log_recorder.place -> t

val not_closed_to_string : not_closed -> string
