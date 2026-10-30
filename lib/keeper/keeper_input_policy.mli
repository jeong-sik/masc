(** Declared conversation input policy, independent of the runtime context cap. *)
type t = Small | Wide
val default : t
val to_string : t -> string
val of_string : string -> t option
val to_yojson : t -> Yojson.Safe.t
