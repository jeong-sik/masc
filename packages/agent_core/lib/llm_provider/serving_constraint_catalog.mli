(** Decode one optional evidence-backed serving constraint from a model catalog
    row. The grouped fields are all-or-nothing except the observed rejection
    and explicit expiry bounds. *)

val parse : entry_id:string -> Otoml.t -> (Serving_constraint.t option, string) result
