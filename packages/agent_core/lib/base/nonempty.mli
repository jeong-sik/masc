(** A list guaranteed to hold at least one element.

    Lets a function reject an empty input at compile time instead of accepting
    (and silently mis-handling) it at runtime. The turn pipeline uses it so the
    tool-execute stage cannot be invoked with zero tool calls — a [StopToolUse]
    turn that carried no tool block must terminate, not be re-issued. *)

type 'a t

(** [None] for the empty list, [Some t] otherwise. *)
val of_list : 'a list -> 'a t option

val to_list : 'a t -> 'a list
val hd : 'a t -> 'a
val length : 'a t -> int
