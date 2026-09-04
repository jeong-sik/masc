(** The wording of a durable approval step, drawn from its typed phase. The
    store persists the phase; this is where the sentence lives. *)

val lifecycle_line : phase:string -> tool:string option -> string
(** A phase this build does not know is named rather than dropped. *)

val fold_line : phases:string list -> tool:string option -> string option
(** One line for a run of steps belonging to the same approval. The run
    collapses to the furthest phase it reached, with problems taking
    precedence over plain success; [continuation_recorded] rides as a suffix
    because it says something the outcome does not. [None] for an empty run. *)
