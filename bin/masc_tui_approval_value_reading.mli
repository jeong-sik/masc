(** Ownership of a decoded Gate input's optional byte reading. *)

type t

val has_strings : (string * Yojson.Safe.t) list -> bool

val create :
  scope:unit ref -> gate_id:string -> fields:(string * Yojson.Safe.t) list ->
  restore_scroll:int -> t

val matches :
  t -> scope:unit ref -> gate_id:string -> fields:(string * Yojson.Safe.t) list -> bool
(** A fresh poll may replace the list with equivalent decoded input. Object
    order and serialized value distinctions remain significant. *)

val restore_scroll : t -> int
