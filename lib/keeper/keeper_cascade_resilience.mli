(** Cascade resilience checks used by turn scheduling. *)

type cascade_resilience =
  { ok : bool
  ; cascade_name : string
  ; model_labels : string list
  ; pure_local : bool
  ; fallback_cascade : string option
  ; blocker : string option
  ; error : string option
  ; hint : string option
  }

val cascade_resilience_of_name : string -> cascade_resilience

val cascade_resilience_of_meta : Keeper_types.keeper_meta -> cascade_resilience

val cascade_resilience_error_message : cascade_resilience -> string option
