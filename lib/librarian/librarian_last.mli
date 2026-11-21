(** What a Keeper's writer keeps of its last asks for the operator's row
    (RFC librarian-call-only-proposes §9.1, §12). Nothing of it is on disk: a
    boot starts with none, and the alarms that read it stay off until the
    next ask ends (§12.2).

    [specs/bug-models/LibrarianWriter.tla] names these [m.last], [m.lastOne],
    [m.lastSil], [m.lastBasis], [m.lastLane] ({!read}), [m.room],
    [m.roomMem], [m.roomLane] ({!room}) and [m.alone]. *)

module Digest := Agent_core.Checkpoint_objects

(** How the last reading ask ended, of those that set it. [Nothing_to_ask],
    a store that stopped, a one-item verdict about another snapshot, and an
    ask no slot declared now was in leave it as it was. *)
type read =
  | Committed
  (** A read or a skip was committed ([m.last = "answered"]). A commit that
      failed sets nothing. *)
  | Refused_not_all_sized of
      { basis : Digest.digest
      (** The snapshot the question was made against ([m.lastBasis]). *)
      ; lane : Librarian_memory_lane.t
      (** The lane value declared when the ask ended: the one whose slots
          the verdict was folded over ([m.lastLane]). *)
      ; slots : (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
      (** Every slot of the walk, as in {!Lane}. *)
      }
  (** No slot answered a question that offered one item, every slot [lane]
      walks refused it, and {!Librarian_bottom.fold} over [lane] was
      [Not_all]: a slot it walks gave no size, or it declares one the
      registry did not admit. The writer rests with no step below one item
      ([m.last = "notall_r"]). This end is kept here and not as a {!Lane};
      E4 reads it and no other end (§12.2). *)
  | Lane of
      { one_item : bool
      (** The question offered one item, with Memory or alone ([m.lastOne]). *)
      ; silent : bool
      (** A slot the lane declared when the ask ended said nothing, or was
          not in the walk ([m.lastSil]). A refusal without a size is not
          silence. *)
      ; basis : Digest.digest
      (** The snapshot the question was made against ([m.lastBasis]). *)
      ; slots : (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
      (** Every slot of the walk, as {!Librarian_read_result.No_answer}
          carries them. *)
      }
  (** No slot answered ([m.last = "lane"]): the RFC's [Refused_by_lane] and
      [Silent_lane]. *)
  | Input_fault of Librarian_unit.input_fault
  (** [m.last = "fault"]. The fault names what the operator sends to pass
      it (§12.4): the line's offset for [Skip_line], the id the file names
      now for [Restart_reading]. *)
  | Ask_failed of Librarian_read_result.failed (** [m.last = "failed"]. *)

(** How the last room ask ended ([m.room]). *)
type room =
  | Made (** Its plan was committed. *)
  | Unchanged (** Its plan changed nothing: no op, or every op left out. *)
  | Stale (** A direct write removed a fact while it was asked (§8.3). *)
  | Not_judged
  (** No slot answered and not every slot declared now refused it for its
      input, or the ask failed. *)
  | Fits_none of
      { memory : Digest.digest (** The snapshot it showed ([m.roomMem]). *)
      ; lane : Librarian_memory_lane.t
      (** The lane value it was asked with ([m.roomLane]). *)
      }
  (** Every slot declared now refused it for its input: Memory alone fits no
      slot's window (E5). *)

(** [silent ~declared slots]: one of [declared] is not in [slots] or said
    nothing there. *)
val silent
  :  declared:Librarian_memory_lane.slot_key list
  -> (Librarian_memory_lane.slot_key * Librarian_slot_outcome.unanswered) list
  -> bool
