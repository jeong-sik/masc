(** What a Goal measures, and what was measured, as values of the same shape.

    A Goal's success condition is one of three shapes: a count out of a
    total, a quantity against a limit, or a condition that holds or does not.
    A measurement is a value of the matching shape. Two values meet only
    through {!pair}, which names the reason when they do not fit, so the
    screens and the verdict check never compare a count with a quantity.

    Every invariant is kept by a constructor, not by a comment: the types are
    [private], and the only ways to build them are the [make_*] functions,
    the shape constructors and the JSON readers, which go through the same
    functions. An empty unit, a count out of zero, an infinite target or
    fifteen out of fourteen cannot be built (RFC
    a-goal-states-its-measure-as-a-typed-value §2). *)

type label = private string
(** One non-empty line: a unit word ("층", "ms", "%") or a condition
    sentence. It is drawn next to numbers and never compared. *)

type count = private int
(** One or more. *)

type finite = private float
(** A number that is neither nan nor an infinity. *)

type direction =
  | At_least
  | At_most

type t = private
  | Count of { noun : label; total : count }
  | Quantity of { unit : label; direction : direction; target : finite }
  | Done_when of { condition : label }

type observed = private
  | Counted of { done_ : int }  (** Zero or more. *)
  | Quantified of { value : finite }
  | Decided of bool

type paired = private
  | Count_pair of { noun : label; total : count; done_ : int }
      (** [done_] is at most [total]. *)
  | Quantity_pair of
      { unit : label; direction : direction; target : finite; value : finite }
  | Done_pair of { condition : label; decided : bool }
(** A measure and a measurement of the same shape. Only {!pair} builds one. *)

type mismatch =
  | Shape_differs
      (** The measurement is not the measure's shape: a quantity for a count,
          a decision for a quantity. *)
  | Count_over_total of { done_ : int; total : int }

val make_label : string -> (label, string) result
(** Refuses a value that is blank or spans more than one line. The text is
    kept as written; it is not trimmed. *)

val make_count : int -> (count, string) result
(** Refuses zero and negative values. *)

val make_finite : float -> (finite, string) result
(** Refuses nan and the infinities. *)

val count : noun:label -> total:count -> t
val quantity : unit:label -> direction:direction -> target:finite -> t
val done_when : condition:label -> t

val counted : int -> (observed, string) result
(** Refuses a negative count. Whether it exceeds the total is a question for
    {!pair}, which knows the total. *)

val quantified : finite -> observed
val decided : bool -> observed

val pair : t -> observed -> (paired, mismatch) result

type reach =
  | Reached
  | Short_of

val reach : paired -> reach
(** A count is reached when it is done in full, a quantity when its value is
    on the allowed side of the target (the target itself included), and a
    condition when it was decided true. How far short a value falls is for
    the screen to write from the {!paired} value; there is no text here. *)

val mismatch_to_string : mismatch -> string

val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result
(** Reads exactly the shape {!to_yojson} writes:
    [{"kind":"count","noun":…,"total":…}],
    [{"kind":"quantity","unit":…,"direction":"at_least"|"at_most","target":…}],
    [{"kind":"done_when","condition":…}]. An unknown kind, a missing field or
    an extra field is refused; nothing is filled in. *)

val observed_to_yojson : observed -> Yojson.Safe.t
val observed_of_yojson : Yojson.Safe.t -> (observed, string) result
(** [{"kind":"counted","done":…}], [{"kind":"quantified","value":…}] or
    [{"kind":"decided","value":…}], read as strictly as {!of_yojson}. *)

val equal : t -> t -> bool
val observed_equal : observed -> observed -> bool
