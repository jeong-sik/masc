(** Pure, durable identity for one Keeper Agent Core API call.

    Retry dimensions are closed sums rather than caller-authored labels.  The
    resulting identifier is safe for use as a single path component and stays
    stable across a process restart: Keeper generation is deliberately not an
    identity field because a crash may advance it while resuming the same
    durable turn. *)

type candidate_attempt =
  | Lane_head
  | Lane_fallback of { ordinal : int }

type context_attempt =
  | Initial_context of { capacity_bytes : int }
  | Context_shrink of
      { ordinal : int
      ; capacity_bytes : int
      }

type thinking_attempt =
  | Runtime_thinking_policy
  | Force_thinking
  | Force_no_thinking

type error =
  | Invalid_keeper_name of string
  | Invalid_trace_id of string
  | Invalid_runtime_id of string
  | Non_positive_keeper_turn_id of int
  | Negative_candidate_attempt of int
  | Negative_context_shrink_attempt of int
  | Non_positive_context_capacity of int

type operation_id_error =
  | Invalid_operation_id_prefix
  | Invalid_operation_id_digest_length
  | Invalid_operation_id_digest_character

type decoding_error =
  | Identity_not_object
  | Identity_fields_invalid
  | Unsupported_schema_version of int
  | Candidate_attempt_invalid
  | Context_attempt_invalid
  | Thinking_attempt_invalid
  | Identity_value_invalid of error

type t
type operation_id = private string

val create
  :  keeper_name:string
  -> trace_id:string
  -> keeper_turn_id:int
  -> runtime_id:string
  -> candidate_index:int
  -> context_shrink_attempt:int
  -> context_capacity_bytes:int
  -> thinking_override:bool option
  -> (t, error) result

val operation_id : t -> operation_id
val operation_id_to_string : operation_id -> string
val operation_id_of_string : string -> (operation_id, operation_id_error) result
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, decoding_error) result
val error_to_string : error -> string
