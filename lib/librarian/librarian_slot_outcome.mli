(** What one slot did with one question (RFC librarian-call-only-proposes
    §7.2).

    An ask walks the lane's slots once and gives every slot one outcome. The
    writer's decision reads four things of an outcome: the slot answered,
    refused for the input's size, refused otherwise, or said nothing. The
    rest names the case on the operator's row.

    This module holds types only. Classifying a slot's visit is done by the
    layer that makes it. How a whole ask ended is
    {!Librarian_read_result}. *)

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
