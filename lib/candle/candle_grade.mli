(** A configured grade identifier. Historical receipts validate syntax only;
    a new appraisal must additionally belong to its captured policy. *)
type t
val to_string : t -> string
val of_string : string -> t option
