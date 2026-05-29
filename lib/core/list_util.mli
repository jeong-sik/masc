(** List utilities — SSOT for cross-module list helpers. *)

val count_if : ('a -> bool) -> 'a list -> int
(** [count_if pred xs] is equivalent to [List.length (List.filter pred xs)]
    but does not allocate the intermediate filter list. Single fold,
    O(n) time, O(1) extra space. *)

val take_last : int -> 'a list -> 'a list
(** [take_last n xs] returns the last [n] elements of [xs].
    Returns [[]] when [n <= 0] and [xs] when [List.length xs <= n]. *)
