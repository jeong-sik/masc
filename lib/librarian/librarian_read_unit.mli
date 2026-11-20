(** One unit of a Keeper's turn log as a question shows it
    (RFC librarian-call-only-proposes §5.3, §5.5).

    The items are the values their stores hold, one row each, in the order
    {!Librarian_unit} says. The question reduces them as §5.5
    says when it writes them out, so one module writes the question's
    bytes. Nothing here is written to the commit log. *)

(** What a turn's [Opened] line said. *)
type opened =
  { runtime : string (** The runtime declaration's id. *)
  ; task : Keeper_turn_log.task_evidence
  ; stimuli : Keeper_turn_log.stimulus list
  }

(** One row as its store holds it. *)
type body =
  | Chat_row of Keeper_chat_store_line_decode.parsed_line
  (** A message carries its role and, on a line a speaker sent, the
      speaker. *)
  | External_row of Keeper_external_attention.item (** Its [actor] sent it. *)
  | Message of Agent_core.Types.message
  | Fragment of
      { file : Keeper_turn_fragments.file
      ; line : Keeper_turn_fragments.line
      }

type item =
  { index : int
  (** Its place in the unit as this question shows it, counted from 0. It
      is not written to the commit log. *)
  ; name : Librarian_unit.item_name
  (** The name a commit that reads through this item writes. *)
  ; body : body
  }

type kind =
  | Turn of
      { turn : int (** Byte offset of the turn's [Opened] line: the turn's id. *)
      ; outcome : Keeper_turn_log.outcome
      (** [Close_missing] and [Process_exited] say the turn's own items
          were closed after it was admitted, not that the turn closed them. *)
      ; opened : opened
      ; unattributed : item list (** Shown without the Task. *)
      ; own : item list (** Shown with the Task. *)
      }
  | Reset of
      { cause : Keeper_turn_log.announced
      ; items : item list (** Shown without a Task. *)
      }

(** An [Unannounced] reset is never one: what it covers cannot be read. *)
type t =
  { line : int (** Byte offset of the unit's line. *)
  ; at : float (** When the line was written: the turn closed, or the reset. *)
  ; kind : kind
  ; missing : Librarian_unit.missing_part list
  }

(** The parts each unit lacks, in unit order. A unit that lacks none is
    left out. *)
val missing_at : t list -> Librarian_unit.missing_at list

(** The unit's first item as a question shows it: the first [unattributed]
    item of a turn, else its first [own] one, or a reset's first item.
    [None] when the read holds no item. *)
val first_item : t -> Librarian_unit.item_name option
