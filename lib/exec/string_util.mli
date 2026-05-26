val contains_substring : string -> string -> bool
(** [contains_substring haystack needle] returns [true] if [needle] is a
    substring of [haystack]. Sliding-window implementation. *)

val contains_substring_ci : string -> string -> bool
(** Case-insensitive version of [contains_substring]. Returns [false] for an
    empty [needle], matching the legacy GH classifier helper. *)
