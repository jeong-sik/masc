(** Readonly shell rejection hints and structured diagnoses. *)

val readonly_shell_token_match : string list -> (string * string) option

val readonly_hint_of_category : string -> string

val diagnosis_of_readonly_category : string -> Exec_core.diagnosis option

val diagnosis_of_block_reason :
  Exec_policy.block_reason -> Exec_core.diagnosis option
