(** Capture a selected installer's stdout while password prompts and stdin stay
    on the operator's terminal. The child is reaped before returning. *)
val capture : string list -> (string, unit) result
