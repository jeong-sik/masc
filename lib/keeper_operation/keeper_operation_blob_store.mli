type t

module Input_ref : sig
  type t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module Outcome_ref : sig
  type t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

module State_ref : sig
  type t
  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type error =
  | Invalid_ref of string
  | Filesystem_error of string
  | Read_error of string
  | Integrity_error of string
  | Kind_mismatch of
      { expected : string
      ; actual : string
      }

val error_to_string : error -> string

val create : base_path:string -> keeper_runtime_dir:string -> t
val root_dir : t -> string

val put_input
  :  t
  -> Keeper_operation_request.Canonical_json.t
  -> (Input_ref.t, error) result

val put_outcome
  :  t
  -> Keeper_operation_request.Canonical_json.t
  -> (Outcome_ref.t, error) result

val put_state
  :  t
  -> Keeper_operation_request.Canonical_json.t
  -> (State_ref.t, error) result

val fetch_input
  :  t
  -> Input_ref.t
  -> (Keeper_operation_request.Canonical_json.t option, error) result

val fetch_outcome
  :  t
  -> Outcome_ref.t
  -> (Keeper_operation_request.Canonical_json.t option, error) result

val fetch_state
  :  t
  -> State_ref.t
  -> (Keeper_operation_request.Canonical_json.t option, error) result
