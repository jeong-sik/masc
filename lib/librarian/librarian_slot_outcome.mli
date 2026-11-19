(** What one slot did with one question, and what one ask ended in
    (RFC librarian-call-only-proposes §7.1, §7.2).

    An ask makes one question, walks the lane's slots once and gives every
    declared slot one outcome. The writer's decision reads four things of an
    outcome: the slot answered, refused for the input's size, refused
    otherwise, or said nothing. The rest names the case on the operator's
    row.

    This module holds types only. Classifying a slot's visit and walking the
    lane are done by the layers that make them. *)

module Digest := Agent_core.Checkpoint_objects

(** A refusal that says the question did not fit this slot. *)
type size_fact =
  | Input_too_large
  (** Counted before sending, typed by the provider as an input overflow, or
      HTTP 413. Nothing was generated. *)
  | Output_over_reserve
  (** Typed as stopped at the output limit: the lane's reserve when one is
      declared, the provider's default otherwise. One generation spent. *)
  | Window_reached
  (** Input and output reached the window, with content or without. One
      generation spent. *)

type refusal =
  | Sized of size_fact
  | Unsized (** The provider refused this request and gave no size. *)

(** No answer and no refusal: nothing about the question is learnt. *)
type silence =
  | Not_called
  (** Not sent: its provider holds it until a stated time, another slot gave
      a seat first, or the walk ended before it. *)
  | Unavailable (** The slot or its runtime cannot be used as declared. *)
  | Busy (** Rate limit, overload, server error, quota. *)
  | Lost (** Transport, body deadline, or a failure no type explains. *)
  | Unusable of Librarian_answer.rejection (** A body came and cannot be used. *)

type t =
  | Slot_answered
  | Refused of refusal
  | Silent of silence

(** What the walk learnt when no slot answered. *)
type lane_result =
  { question : Librarian_question_id.t
  ; basis : Digest.digest
  (** The snapshot the ask read Memory from. A verdict a one-item question
      gave about an older Memory is not used (§7.4). *)
  ; head : Librarian_unit.item_ref (** The first item the question carried. *)
  ; offered : Librarian_unit.offered
  ; slots : (Librarian_memory_lane.slot_key * t) list
  (** Every declared slot, HTTP then CLI, in declared order. *)
  }

(** The walk stopped on masc's side: a measurement or an attempt could not
    start, or a callback failed. Not a slot's outcome. *)
type failed =
  | Raised (** The ask raised. Its text goes to the structured log. *)
  | Flow_stopped

(** What a question read and showed, as the writer commits it (§8.1, §8.4).
    The question's text is not here: the ask sends it and the writer does
    not read it. *)
type question =
  { id : Librarian_question_id.t
  ; shown : Librarian_plan.shown
  (** [shown.memory] is [Some] exactly when the question showed Memory. *)
  ; starts_after : Librarian_log.position
  (** Where reading stood when the question was made. A [Read] commit is
      taken only while reading still stands there. *)
  ; through : Librarian_log.position (** Where reading stands once the answer is committed. *)
  ; covered : Keeper_turn_log.mark
  (** Where the stores ended at the last unit [through] covers whole. A unit
      read in part leaves it at that unit's start. *)
  ; turn_log : Keeper_turn_log.Log_id.t
  ; turn_log_offset : int
  (** Byte offset of the first line reading has not finished (§5.4). *)
  ; missing : Librarian_unit.missing_part list
  }

(** How one ask of a reading question ended. *)
type ask_result =
  | Answered of
      { question : question
      ; answer : Librarian_answer.t
      ; slot : string (** The id of the slot that answered. *)
      ; offered : Librarian_unit.offered
      }
  | Nothing_to_ask
  | Refused_by_lane of lane_result
  (** No slot answered and at least one refused the question. *)
  | Silent_lane of lane_result (** No slot answered and none refused. *)
  | Nothing_readable of
      { through : Librarian_unit.item_ref
      ; missing : Librarian_unit.missing_part list
      }
  (** The range holds no item that can be read. *)
  | Span_unknown of
      { line : int (** Byte offset of the [Unannounced] reset. *)
      ; before : Keeper_turn_log.mark
      ; after : Keeper_turn_log.mark
      }
  (** An [Unannounced] reset with no unit holding an item before it. No
      model is called. *)
  | Memory_diverged of
      { expected : Digest.digest (** The snapshot the last commit line names. *)
      ; observed : Digest.digest (** The snapshot the file holds. *)
      }
  | Input_fault of Librarian_unit.input_fault
  | Ask_failed of failed
