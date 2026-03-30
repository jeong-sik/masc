(** Shared string utility functions. *)

val contains_substring : string -> string -> bool
(** [contains_substring haystack needle] returns [true] if [needle]
    appears anywhere inside [haystack].  Returns [true] when [needle]
    is empty. *)
