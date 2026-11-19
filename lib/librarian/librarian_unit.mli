(** The parts of a Keeper's turn log a question carries
    (RFC librarian-call-only-proposes §5.3 to §5.5, §7.1).

    A [Closed] line and a [Reset] line are each one unit. What lies in a unit
    is counted in items: the rows the other side sent come first, then the
    messages. An item is named by its unit's line and its number in the
    unit. The line decides the numbers, not the content, so a bundle that
    goes missing or comes back moves no other item's number.

    This module holds the types the asking layers share. Reading the turn
    log, reading a unit's content and making the question are done
    elsewhere. *)

module Digest := Agent_core.Checkpoint_objects

(** One item's name. *)
type item_ref =
  { line : int (** Byte offset of the unit's line in the turn log. *)
  ; index : int (** The item's number in its unit, counted from 0. *)
  }

(** Content a unit's line names that is not there when the question is
    made. The items that are there are still read. Each missing part says
    which item numbers it stands in for, and the commit line records it.

    A part whose size the line gives stands in for that many items: a
    bundle for the [take] messages of its slice, the external store for the
    rows its two marks count. A byte range of a file stands in for one item:
    the line gives its bytes, not its rows. *)
type missing_part =
  | Bundle of
      { bundle : Digest.digest
      ; first : item_ref
      ; count : int
      }
  | History_bytes of { item : item_ref }
  | Internal_bytes of { item : item_ref }
  | Chat_bytes of { item : item_ref }
  | External_rows of
      { first : item_ref
      ; count : int
      }
  | Undecodable_fragment_line of { item : item_ref }
  (** A line of an official-client history file that does not decode. *)

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

(** What a turn's [Opened] line said. *)
type opened =
  { runtime : string (** The runtime declaration's id. *)
  ; task : Keeper_turn_log.task_evidence
  ; stimuli : Keeper_turn_log.stimulus list
  }

(** One item as the question shows it: reduced as §5.5 says, and written
    out. A tool call keeps its id and name, a tool result its id and kind, a
    tool observation its index, tool name and outcome. A row keeps its
    sender. *)
type item =
  { index : int (** Its number in the unit. *)
  ; text : string
  }

type kind =
  | Turn of
      { turn : int (** Byte offset of the turn's [Opened] line: the turn's id. *)
      ; outcome : Keeper_turn_log.outcome
      (** [Close_missing] and [Process_exited] say the turn's own items
          were closed after it was admitted, not that the turn closed them. *)
      ; opened : opened option
      (** [None]: the [Opened] line did not decode and an operator passed
          over it. The turn is read without its Task. *)
      ; unattributed : item list
      (** Closed before the turn's [baseline], or everything when a [Reset]
          followed its [Opened]. Shown without the Task. *)
      ; own : item list (** Shown with the Task. *)
      }
  | Reset of
      { cause : Keeper_turn_log.announced
      ; items : item list (** Shown without a Task. *)
      }

(** One unit as a question shows it. An [Unannounced] reset is never one:
    what it covers cannot be read. *)
type t =
  { line : int (** Byte offset of the unit's line. *)
  ; at : float (** When the line was written: the turn closed, or the reset. *)
  ; kind : kind
  ; missing : missing_part list
  }

(** What one question carried. *)
type offered =
  { units : int
  ; head_items : int (** Items of its first unit. *)
  }
