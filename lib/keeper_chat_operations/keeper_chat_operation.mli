(** Durable Keeper chat operation facts.

    Operation identity is the validated producer request id. The immutable
    admission digest remains the idempotency authority even when a queued
    operation is edited; [execution_digest] identifies the body that will
    actually execute. Terminal facts never retain the input body. *)

module Operation_id : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
end

type failure_kind =
  | Interrupted_by_restart
  | Turn_cancelled
  | Turn_exception
  | Store_unavailable
  | No_queued_operation
  | Invalid_input
  | Turn_invariant
  | Delivery_failed

val all_failure_kinds : failure_kind list
val failure_kind_to_string : failure_kind -> string
val failure_kind_of_string : string -> (failure_kind, string) result

type failure =
  { kind : failure_kind
  ; detail : string
  ; outcome_ref : string option
  }

type state =
  | Queued
  | Running of { started_at : float }
  | Succeeded of
      { completed_at : float
      ; outcome_ref : string
      }
  | Failed of
      { completed_at : float
      ; failure : failure
      }
  | Cancelled of { completed_at : float }

type t =
  { operation_id : Operation_id.t
  ; admission_digest : string
  ; execution_digest : string
  ; sequence : int64
  ; source : Yojson.Safe.t
  ; input : Yojson.Safe.t option
  ; state : state
  ; created_at : float
  }

val state_to_string : state -> string
val is_terminal : state -> bool
val to_json : t -> Yojson.Safe.t

type canonical_json_error =
  | Duplicate_object_key of string
  | Non_finite_float

val canonical_json
  :  Yojson.Safe.t
  -> (Yojson.Safe.t, canonical_json_error) result
(** Recursively sort object keys while rejecting duplicate object keys and
    non-finite floats. *)

val canonical_json_string : Yojson.Safe.t -> (string, string) result
val admission_digest : source:Yojson.Safe.t -> input:Yojson.Safe.t -> (string, string) result
val execution_digest : Yojson.Safe.t -> (string, string) result
val validate_timestamp : field:string -> float -> (unit, string) result
val validate_nonblank : field:string -> string -> (string, string) result
