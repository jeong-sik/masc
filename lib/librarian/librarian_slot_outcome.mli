(** What one slot did with one question (RFC librarian-call-only-proposes
    §7.2).

    An ask walks the lane's slots once and gives every slot one outcome. The
    writer's decision reads four things of an outcome: the slot answered,
    refused for the input's size, refused otherwise, or said nothing. The
    rest names the case on the operator's row.

    The types are {!Exact_lane_slot_outcome}'s, the table every exact lane
    reads, with {!Librarian_answer.rejection} as the lane's rejection. Each
    constructor is documented there and is given again here under the same
    name: a type that takes the rejection is given again as its [_of] type,
    and the name without it is that type of the Librarian's rejection.

    This module holds types only. Classifying a slot's visit is done by the
    layer that makes it. How a whole ask ended is
    {!Librarian_read_result}. *)

(** A refusal that says the question did not fit this slot. *)
type size_fact = Exact_lane_slot_outcome.size_fact =
  | Input_too_large
  | Output_over_reserve
  | Window_reached

type refusal = Exact_lane_slot_outcome.refusal =
  | Sized of size_fact
  | Unsized

type 'rejection silence_of = 'rejection Exact_lane_slot_outcome.silence =
  | Not_called
  | Unavailable
  | Busy
  | Overdue
  | Lost
  | Unusable of 'rejection

(** No answer and no refusal: nothing about the question is learnt. *)
type silence = Librarian_answer.rejection silence_of

type 'rejection unanswered_of = 'rejection Exact_lane_slot_outcome.unanswered =
  | Refused of refusal
  | Silent of 'rejection silence_of

(** A slot that gave no answer. An ask that ends with no answer carries one
    of these for every slot, so its slots cannot hold an answer. *)
type unanswered = Librarian_answer.rejection unanswered_of

type 'rejection t_of = 'rejection Exact_lane_slot_outcome.t =
  | Slot_answered
  | Unanswered of 'rejection unanswered_of

type t = Librarian_answer.rejection t_of
