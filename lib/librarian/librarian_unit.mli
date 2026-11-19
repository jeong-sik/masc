(** What a commit line names of the units of a Keeper's turn log
    (RFC librarian-call-only-proposes §5.3, §5.4, §8.1).

    A [Closed] line and a [Reset] line are each one unit. What lies in a unit
    is counted in items, and an item is named by its unit's line and its
    number in the unit, counted from 0. A commit line stores that number
    ([Librarian_log.within]), so the numbers are a function of the turn
    log's lines alone, never of what a store holds when it is read. Every
    row of every store is one item, and the marks give each store's row
    count: a bundle slice gives [take], and each store's two marks give the
    rows between them. A store that loses rows, or a bundle that goes
    missing or comes back, moves no other item's number.

    A [Turn] splits every store at its [Opened] line's [baseline]: before it
    is [unattributed], after it is [own], and when a [Reset] followed that
    [Opened] everything is [unattributed]. A [Reset] unit is one segment.
    Numbers run through [unattributed] and then [own]. Inside one segment
    the rows the other side sent come first, then the messages, in this
    order: chat rows, external rows, Agent-Core messages in slice order,
    official-client history rows, official-client internal rows.

    These types are written to the commit log, so they hold no type another
    store owns. The unit as a question shows it is {!Librarian_read_unit}. *)

module Digest := Agent_core.Checkpoint_objects

(** Content a unit's line names that is not there when the question is
    made. The items that are there are still read. Each part names the item
    numbers in its unit that it stands in for. *)
type missing_part =
  | Bundle of
      { bundle : Digest.digest
      ; first : int
      ; count : int (** The slice's [take]. *)
      }
  | History_bytes of
      { first : int
      ; count : int
      }
  | Internal_bytes of
      { first : int
      ; count : int
      }
  | Chat_bytes of
      { first : int
      ; count : int
      }
  (** The rows the marks count that the file no longer holds. *)
  | External_rows of
      { first : int
      ; count : int
      }
  | Undecodable_fragment_line of { item : int }
  (** A row of an official-client file that does not decode. *)

(** What is missing from the unit at [line]. *)
type missing_at =
  { line : int (** Byte offset of the unit's line in the turn log. *)
  ; parts : missing_part list
  }

(** Why the turn log cannot be read from where reading stands. The reader
    looks in this order: the turn log's id, the stored offset, the lines.
    None of these stops Memory writes; only reading rests. *)
type input_fault =
  | Line_unreadable of { offset : int }
  (** A line that does not decode, with no unit holding an item before it.
      An operator's [Skip_line] passes it. *)
  | Turn_log_replaced of
      { expected : Keeper_turn_log.Log_id.t (** The id the commit log names. *)
      ; observed : Keeper_turn_log.Log_id.t option
      (** The id the file's first line names. [None]: the file has no
          [Log_started]. *)
      }
  | Position_lost of
      { offset : int
      ; length : int (** The file's length. *)
      }
  (** The same file, and the stored offset is past its end or not at the
      start of a line. *)
  | Content_unreadable of { line : int }
  (** A bundle the unit at [line] names is there and cannot be read now. *)
