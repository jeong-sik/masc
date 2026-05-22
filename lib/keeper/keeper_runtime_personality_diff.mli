(** Personality-text drift diagnostic helpers for keeper runtime. *)

val personality_text_equal : string -> string -> bool

val personality_field_diff_entry
  :  string
  -> string
  -> string
  -> string option

val personality_diff_summary
  :  (string * string * string) list
  -> string list

val personality_field_diff_summary
  :  field:string
  -> current:string
  -> target:string
  -> string option
