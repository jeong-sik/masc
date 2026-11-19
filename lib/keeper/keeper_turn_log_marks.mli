(** Counting a history's closed messages and naming a run of them
    (RFC librarian-call-only-proposes §5.1).

    A mark counts closed messages, not closed turns. A purge that rewrites
    one message folds every closed turn after it into one bundle: the number
    of turns changes, the messages and their order do not. So a position
    counted in messages survives a purge, and a run of messages is named by
    the bundles that hold it when the line is written.

    This module counts and cuts. It reads no object. *)

module Objects := Agent_core.Checkpoint_objects

(** The messages the head's segments and closed turns hold. The open turn's
    messages are not counted: a line written outside a turn closes them
    first. *)
val closed_messages : Objects.history -> int

(** Closed turns, oldest first, and the number of the first message of the
    first one. Messages are numbered from 0. *)
type covered =
  { first : int
  ; turns : Objects.turn list
  }

(** The turns the head holds itself, after its last segment. *)
val of_head : Objects.history -> covered

(** The turns of the segment just before [covered], put in front of it. The
    caller reads the segment when a run starts before {!covered.first}. *)
val with_segment_before : Objects.segment -> covered -> covered

type range_error =
  | Starts_before_covered of
      { from : int
      ; first : int
      }
  (** Read the segment before and ask again. *)
  | Ends_after_covered of
      { through : int
      ; last : int
      }
  | Backwards of
      { from : int
      ; through : int
      }

(** The messages numbered [from] up to, not including, [through], as slices
    of the bundles that hold them, in order. Empty when [from = through]. *)
val slices
  :  covered
  -> from:int
  -> through:int
  -> (Keeper_turn_log.slice list, range_error) result
