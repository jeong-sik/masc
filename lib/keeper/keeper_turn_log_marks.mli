(** Counting a history's closed messages and naming a run of them
    (RFC librarian-call-only-proposes §5.1).

    A mark counts closed messages, not closed turns. A purge that rewrites
    one message folds every closed turn after it into one bundle: the number
    of turns changes, the messages and their order do not. So a position
    counted in messages survives a purge, and a run of messages is named by
    the bundles that hold it when the line is written.

    This module counts and cuts. It reads no object: the caller's [load]
    does. *)

module Objects := Agent_core.Checkpoint_objects

(** The messages the head's segments and closed turns hold. The open turn's
    messages are not counted: a line written outside a turn closes them
    first. *)
val closed_messages : Objects.history -> int

(** Closed turns that follow one another, and where in the history they
    start. Only {!of_head} and {!with_segment_before} make one, so its turns
    and its first message number always agree. *)
type covered

(** The turns the head holds itself, after its last segment. *)
val of_head : Objects.history -> covered

(** The number of the first message covered. Messages are numbered from 0. *)
val first : covered -> int

type 'error segment_error =
  | Nothing_before (** The covered turns already start at message 0. *)
  | Not_read of 'error (** What [load] answered. *)
  | Does_not_fit of
      { first : int
      ; segment_messages : int
      ; has_previous : bool
      }
  (** What [load] gave is not the segment just before: it holds more
      messages than there are before {!first}, or it reaches message 0 and
      names a segment before it, or it stops short of message 0 and names
      none. *)

(** The turns of the segment just before, put in front. [load] is called
    once, with the name the covered turns hold for that segment. The caller
    never chooses which segment is read, so it cannot hand in another one
    that happens to hold as many messages. *)
val with_segment_before
  :  load:(Objects.digest -> (Objects.segment, 'error) result)
  -> covered
  -> (covered, 'error segment_error) result

type range_error =
  | Starts_before_covered of
      { from : int
      ; first : int
      }
  (** Put the segment before in front with {!with_segment_before} and ask
      again. *)
  | Ends_after_covered of
      { through : int
      ; last : int
      }
  | Backwards of
      { from : int
      ; through : int
      }

(** The messages numbered [from] up to, not including, [through], as slices
    of the bundles that hold them, in order. No slice when [from = through].
    A run outside what is covered is an error even when it is empty. *)
val slices
  :  covered
  -> from:int
  -> through:int
  -> (Keeper_turn_log.slice list, range_error) result
