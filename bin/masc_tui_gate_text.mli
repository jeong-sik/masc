(** The wording of a durable approval step, drawn from its typed phase. The
    store persists the phase; this is where the sentence lives. *)

val lifecycle_line : phase:string -> tool:string option -> string
(** A phase this build does not know is named rather than dropped. *)
