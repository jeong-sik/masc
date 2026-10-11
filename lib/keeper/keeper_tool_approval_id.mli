(** Identity of one MASC approval admission, independent of provider call IDs. *)
type t
val fresh : unit -> t
val to_string : t -> string
val of_string : string -> (t, string) result
val equal : t -> t -> bool
