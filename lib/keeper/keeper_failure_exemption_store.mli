(** Durable consumption state for bounded crash-accounting exemptions. *)

type state =
  { invalid_request_count : int
  ; empty_completion_count : int
  }

type error =
  | Invalid_keeper_name of string
  | Invalid_state of state
  | Malformed of string
  | Io_error of string

val zero : state
val error_to_string : error -> string
val path_for : base_path:string -> keeper_name:string -> string
val load : base_path:string -> keeper_name:string -> (state option, error) result
val save : base_path:string -> keeper_name:string -> state -> (unit, error) result
val clear : base_path:string -> keeper_name:string -> (unit, error) result
