(** Typed codec for the Board post-detail [format] query parameter. *)

type t =
  | Nested
  | Flat

type error = Unsupported of string

val default : t
val to_wire : t -> string
val of_query : string option -> (t, error) result
val error_json : error -> Yojson.Safe.t
