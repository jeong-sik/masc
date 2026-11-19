(** What a commit line names of the units of a Keeper's turn log
    (RFC librarian-call-only-proposes §5.3, §5.4, §8.1).

    A [Closed] line and a [Reset] line are each one unit. A [Turn] splits
    every store at its [Opened] line's [baseline]: before it is
    [unattributed], after it is [own], and when a [Reset] followed that
    [Opened] everything is [unattributed]. A [Reset] unit is one segment.
    A question shows [unattributed] and then [own]. Inside one segment the
    rows the other side sent come first, then the messages, in this order:
    chat rows, external rows, Agent-Core messages in slice order,
    official-client history rows, official-client internal rows.

    A part of a unit that is not there is named the way the unit's line
    names it: a bundle slice, a range of one file's bytes, a range of
    external rows. Rows a file no longer holds are not counted, so one
    store's loss changes nothing another store's part says.

    These types are written to the commit log, so they hold no type another
    store owns. The unit as a question shows it is {!Librarian_read_unit}. *)

(** From [from] to [until]: bytes for a file a mark measures in bytes, rows
    for the external store. [until] is the later mark's value. *)
type range =
  { from : int
  ; until : int
  }

(** Content a unit's line names that is not there when the question is
    made. The parts that are there are still read. *)
type missing_part =
  | Bundle of Keeper_turn_log.slice (** A slice whose bundle is not stored. *)
  | History_bytes of range
  | Internal_bytes of range
  | Chat_bytes of range
  (** Bytes between the unit's two marks that the file no longer holds. *)
  | External_rows of range
  (** Rows between the unit's two marks that the file no longer holds. *)
  | Undecodable_history_line of { offset : int }
  | Undecodable_internal_line of { offset : int }
  (** A row of an official-client file that does not decode, by the byte
      offset where the row starts. *)

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
