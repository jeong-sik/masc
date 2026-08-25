(** Keeper instruction comparison used by runtime reconciliation. *)

val text_equal : string -> string -> bool
(** [text_equal left right] compares the exact prompt text seen by the model
    after the canonical prompt-size normalization. *)
