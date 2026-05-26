(** Error classification and breaker state types. *)

type error_class =
  | Path_not_found
  | Path_not_allowed
  | Cwd_not_directory
  | Shell_exit_nonzero
  | Other

module Path_check_error = Keeper_path_check_error

val classify_path_check_prefix : string -> error_class option
val classify_error : string -> error_class
val error_class_to_string : error_class -> string

type failure_signature =
  { ts : float
  ; cls : error_class
  ; fingerprint : string
  }

val recent_failures_capacity : int

type breaker_state =
  { mutable consecutive_class : error_class
  ; mutable consecutive_count : int
  ; mutable total_tripped : int
  ; mutable last_tripped_at : float option
  ; mutable recent_failures : failure_signature list
  }
