(** Canonical form of a JSON request: object members sorted by key,
    duplicate members rejected, integral floats written as integers. *)

val canonical : Yojson.Safe.t -> (Yojson.Safe.t, string) result

(** [Error] when an object repeats a member name. *)
val unique : (string * 'a) list -> (unit, string) result

(** Maps in order and stops at the first [Error]. *)
val traverse : ('a -> ('b, 'e) result) -> 'a list -> ('b list, 'e) result
