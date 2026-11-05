(** List utilities — SSOT for cross-module list helpers. *)

val count_if : ('a -> bool) -> 'a list -> int
(** [count_if pred xs] is equivalent to [List.length (List.filter pred xs)]
    but does not allocate the intermediate filter list. Single fold,
    O(n) time, O(1) extra space. *)

val strip_prefix : equal:('a -> 'b -> bool) -> 'a list -> 'b list -> 'b list option
(** [strip_prefix ~equal prefix xs] is [Some rest] when [xs] is the elements of
    [prefix] followed by [rest], each pair compared with [equal prefix_element
    xs_element]. It is [None] when [xs] is shorter than [prefix] or an element
    differs. [strip_prefix ~equal [] xs] is [Some xs]. The two lists may hold
    different element types. *)

val is_prefix : equal:('a -> 'b -> bool) -> 'a list -> 'b list -> bool
(** [is_prefix ~equal prefix xs] is [true] when [strip_prefix ~equal prefix xs]
    is [Some _]: [xs] starts with [prefix]. The empty list is a prefix of every
    list. *)

val take_last : int -> 'a list -> 'a list
(** [take_last n xs] returns the last [n] elements of [xs].
    Returns [[]] when [n <= 0] and [xs] when [List.length xs <= n]. *)
