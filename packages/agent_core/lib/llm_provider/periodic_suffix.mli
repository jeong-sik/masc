(** The longest suffix of a byte string that is one unit written over and
    over, verbatim.

    A suffix has period [p] when every byte equals the byte [p] positions
    before it, so the suffix is copies of its first [p] bytes (the last copy
    may be partial). The smallest such [p] is the unit the generation is
    stuck on: ["!!!!"] has period 1, ["the the the "] period 4, a five-line
    chant period 43. Only exact repetition counts; two copies of a thought
    with one word changed are not periodic. *)

type t =
  { span : int (** bytes of the suffix that repeat, counted from the end *)
  ; period : int (** bytes of the repeated unit, the smallest period of that suffix *)
  }

val find : string -> max_period:int -> min_copies:int -> t option
(** The longest suffix whose smallest period is at most [max_period] and
    which holds at least [min_copies] copies of that period ([span >=
    min_copies * period]). [None] when no suffix qualifies, and for
    [max_period < 1] or [min_copies < 2]. Linear in the string length
    (prefix function of the reversed string). *)

val cycle : string -> t -> string
(** The repeated unit: the first [period] bytes of the periodic suffix. *)
