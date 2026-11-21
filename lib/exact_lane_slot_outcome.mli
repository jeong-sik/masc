(** What one slot of an exact lane did with one request (RFC
    curator-narrows-a-refused-batch-and-sets-a-refused-fact-aside §4.7, RFC
    librarian-call-only-proposes §7.2).

    A walk over a lane's slots gives every slot one outcome. A lane's
    decision reads four things of an outcome: the slot answered, refused for
    the request's size, refused otherwise, or said nothing. The rest names
    the case on the operator's row. What a lane does with an outcome is the
    lane's own policy, and no policy is held here.

    ['rejection] is why the lane's own check refused a body that came. No
    other constructor names a lane, so every lane reads one refusal alike.

    This module holds types only. {!Exact_lane_slot_visit} classifies what
    a walk saw at a slot. *)

(** A refusal that says the request did not fit this slot. *)
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

(** No answer and no refusal. *)
type 'rejection silence =
  | Not_called
  (** Not sent: its provider holds it until a stated time, another slot gave
      a seat first, or the walk ended before it. *)
  | Unavailable (** The slot or its runtime cannot be used as declared. *)
  | Busy (** Rate limit, overload, server error, quota. *)
  | Overdue
  (** Sent, and a deadline on the request's own work passed: the first
      token, the wall clock, the HTTP operation, or a body. *)
  | Lost
  (** Transport, a deadline that passed before the request was sent or on an
      idle stream, or a failure no type explains. *)
  | Unusable of 'rejection (** A body came and cannot be used. *)

(** A slot that gave no answer. A walk that ends with no answer carries one
    of these for every slot, so its slots cannot hold an answer. *)
type 'rejection unanswered =
  | Refused of refusal
  | Silent of 'rejection silence

type 'rejection t =
  | Slot_answered
  | Unanswered of 'rejection unanswered
