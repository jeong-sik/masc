(** Canonical producer request identity, shared by operation journals and
    execution scopes. Parsing preserves the producer's exact scalar. *)
type t
val of_string : string -> (t, string) result
val to_string : t -> string
val equal : t -> t -> bool
