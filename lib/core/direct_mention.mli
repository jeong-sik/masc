(** Exact direct-mention syntax at text ingress boundaries.

    This module only parses syntax; it does not decide whether a target exists,
    is relevant, or should wake.  Callers persist or type the returned target
    identities and make routing decisions at their own boundary. *)

val targets_of_content : string -> string list
(** Every whitespace-delimited [@target] token, ASCII case-folded, with
    non-word edge punctuation removed and duplicates eliminated.  Internal
    punctuation is preserved, so [mail@alice.example] never becomes [alice]. *)
