(** Durable Keeper chat operation facts.

    Operation identity is the validated producer request id. The immutable
    admission digest remains the idempotency authority even when a queued
    operation is edited; [execution_digest] identifies the body that will
    actually execute. Terminal facts never retain the input body. *)

module Operation_id = Keeper_operation_id

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

(** The state's name without its facts: the word the operation API writes in
    [state]. The operation object, the queued operation list and the stream's
    [KEEPER_CHAT_OPERATION_ACCEPTED] event spell it with {!to_wire}, and
    {!of_wire} reads it back. *)
module State_name : sig
  type t =
    | Queued
    | Running
    | Succeeded
    | Failed
    | Cancelled

  val to_wire : t -> string

  val of_wire : string -> (t, string) result
  (** Inverse of {!to_wire}. Any other text, including another case of the
      same word, is an [Error] that names it. *)
end

val state_name : state -> State_name.t

type batch_membership = { execution_id : Operation_id.t; input_digest : string }

type t =
  { operation_id : Operation_id.t
  ; batch_membership : batch_membership option
  ; admission_digest : string
  ; execution_digest : string
  ; sequence : int64
  ; source : Yojson.Safe.t
  ; input : Yojson.Safe.t option
  ; state : state
  ; created_at : float
  }

val state_to_string : state -> string
(** Lowercase label for logs and for the replies that only acknowledge a
    submission: the board context inference response, the Keeper message tool
    result and the channel gate's reply text. The operation API spells the
    state with {!State_name.to_wire}. *)

val is_terminal : state -> bool
val to_json : t -> Yojson.Safe.t
(** Internal operation facts, including the original diagnostic. *)

val to_status_json : t -> Yojson.Safe.t
(** What the Keeper that submitted the operation reads back: the operation id,
    creation time, the batch execution id when the operation was coalesced, and
    the state with its terminal facts. State and failure fields are the ones
    {!to_json} reports. The admission and execution digests, [source] and the
    queued [input] are left out; the reader sent that request. No [schema] key:
    the reader asked the status tool about one operation it named, so the reply
    needs no tag to say what kind of object it is. *)

val public_failure_message : failure_kind -> string
(** Fixed public message selected only by the closed failure kind. It never
    accepts a diagnostic, filesystem path or provider error payload. *)

val to_public_json : t -> Yojson.Safe.t
(** Public operation state. Failed operations expose the typed failure code,
    fixed safe message and their operation identity as [incident_id]. Private
    failure diagnostics and diagnostic outcome references are omitted; the
    original immutable operation remains available to internal consumers.
    Queued/running/success/cancel state and caller-owned source/input are
    unchanged. Keeper-scoped content redaction remains an outer MASC boundary. *)

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
