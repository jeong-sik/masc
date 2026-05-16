(** Pre-flight validation for keeper autonomous operations.
    Checks GitHub auth, repo accessibility, and keeper identity
    before starting work. All checks are read-only. *)

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

val cascade_resilience_to_json : cascade_resilience -> Yojson.Safe.t

val cascade_resilience_error_message : cascade_resilience -> string option

val handle_keeper_preflight_check :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
