(** Neutral literal-word projections from typed Shell IR. *)

val flat_stage_words : Masc_exec.Shell_ir.t -> string list
(** Flatten all literal stage words across pipeline segments. Stages containing
    a non-literal argument are omitted. The result is for redacted logging only
    and carries no authorization meaning. *)
