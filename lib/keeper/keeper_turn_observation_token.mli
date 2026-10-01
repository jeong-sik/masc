(** Process-local identity of one live observation, distinct from the durable
    operation identity and the display turn counter. Create once per execution
    attempt and capture it in callbacks; never reuse it for a continuation. *)
type t
val fresh : unit -> t
val equal : t -> t -> bool
