val contains_substring : string -> string -> bool
(** [contains_substring haystack needle] returns [true] if [needle] is a
    substring of [haystack]. Uses [Base.String.is_substring] internally. *)
