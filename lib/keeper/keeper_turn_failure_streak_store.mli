(** Durable consecutive Keeper turn-failure observation.

    The streak describes the same persisted conversation/checkpoint that a
    Keeper resumes after process restart. Absence means zero; positive counts
    use the current strict schema. *)

type error =
  | Invalid_keeper_name of string
  | Invalid_count of int
  | Malformed of string
  | Io_error of string

val error_to_string : error -> string
val path_for : base_path:string -> keeper_name:string -> string
val load : base_path:string -> keeper_name:string -> (int option, error) result
val save : base_path:string -> keeper_name:string -> int -> (unit, error) result
val clear : base_path:string -> keeper_name:string -> (unit, error) result
