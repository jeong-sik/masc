(** Shared string utility functions. *)

val contains_substring : string -> string -> bool
(** [contains_substring haystack needle] returns [true] if [needle]
    appears anywhere inside [haystack].  Returns [true] when [needle]
    is empty. *)

val contains_substring_ci : string -> string -> bool
(** Case-insensitive version of [contains_substring].
    Returns [false] when [needle] is empty, matching the behavior
    of the original per-module [contains_ci] helpers. *)
