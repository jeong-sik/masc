(** Which alarms one Keeper's writer has on, and the level they give (RFC
    librarian-call-only-proposes §12.2). One function over closed
    constructors, from what the writer holds now. Nothing is stored: a
    restart computes it again from the state, so the alarms that read the
    last asks stay off until the next one ends.

    The names are [specs/bug-models/LibrarianWriter.tla]'s [E1] to [E5],
    [W1] and [W3], under [E4Rule = "held_now"] and [E5Rule = "held_now"]. W2
    reads where the Keeper's latest request started (§11), which the writer
    does not hold. An alarm stops nothing: it is read, not a gate. *)

module Digest := Agent_core.Checkpoint_objects

type alarm =
  | E1 (** The store is stopped. *)
  | E2
  (** [Refused_at_bottom]: every slot declared refused the head item's
      question for its size, and no slot says the item fits below. *)
  | E3
  (** Something is unread and the last reading ask ended in an input fault
      or failed. *)
  | E4
  (** Something is unread, and the last reading ask that set an end offered
      one item that every slot declared then refused or held a size fact
      for, not every one with a size
      ({!Librarian_last.Refused_not_all_sized}), about the snapshot and the
      lane value held now. The writer's state is not read: the ask a pulse
      starts from the rest leaves it on. *)
  | E5
  (** The last room ask fit no slot, about the Memory and the lane value
      held now. *)
  | W1
  (** The writer is booting, or something is unread and there is no lane
      value, no reading ask ended since the boot, or the last one ended on
      the lane. *)
  | W3 (** The last committed read was of an item alone, without Memory. *)

(** What the level is read from. *)
type writer =
  | Booting (** What is unread cannot be told: the boot has not read the tail. *)
  | Running of
      { machine : Librarian_machine.t
      ; unread : bool
      (** {!Librarian_unread.has_unread} from the store's tail. [false] for
          a stopped store, which has no tail to read from. *)
      }
  | Retired (** The writer takes nothing more, and has no alarm. *)

(** The alarms on, in the order of {!alarm}. *)
val alarms : writer -> alarm list

(** {1 Whether a verdict is about what the writer holds now}

    The two halves of "held now" that {!E4} and {!E5} read of the verdict
    the last ask left. The health row says the same of the end it shows by
    calling these, so a row and its alarms cannot say different things. *)

(** Whether the snapshot is the one the store's last line names now. [false]
    for a stopped store, which names none. *)
val snapshot_held_now : Librarian_machine.t -> Digest.digest -> bool

(** Whether the lane value is the one declared now. [false] for a writer
    with no lane value. *)
val lane_value_held_now : Librarian_machine.t -> Librarian_memory_lane.t -> bool

type level =
  | Ok
  | Warn
  | Error

(** [Error] with an [E] alarm on, [Warn] with only [W] alarms, [Ok] with none. *)
val level : alarm list -> level
