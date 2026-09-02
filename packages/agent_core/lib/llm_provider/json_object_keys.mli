(** Resolving a repeated object key, once, for every payload boundary.

    JSON allows an object to bind the same key twice; Yojson keeps both
    bindings and [Yojson.Safe.Util.member] reads the first. A payload that
    crosses a boundary with a repeat is therefore read one way and refused by a
    strict encoder later, after the work it described has already happened. *)

val deduplicate : Yojson.Safe.t -> Yojson.Safe.t * string list
(** [deduplicate json] returns [json] with every repeated object key resolved
    to its FIRST binding -- the one [member] already reads, so no value
    downstream moves -- together with the names that were dropped, in the order
    they were sent and including nested occurrences. An empty list means every
    key was bound once. Non-object values are returned unchanged. *)
