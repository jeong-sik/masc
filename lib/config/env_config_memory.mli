(** Shared env parsing helpers for memory-related keeper knobs.

    These helpers preserve the repository convention that blank env values are
    treated as unset while keeping invalid-value handling visible in logs. *)

type invalid_bool_policy =
  | Default
  | Fail_closed

val parse_bool_token : string -> bool option

val env_opt : string -> string option
val get_int_logged : string -> default:int -> int
val get_bool_logged : ?invalid:invalid_bool_policy -> string -> default:bool -> bool
