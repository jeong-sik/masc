(** Current-schema-only durable OAS exact-flow preference evidence.

    One journal is bound to exactly one Keeper generation and execution
    surface. The complete owner-bound evidence set is integrity checked before
    any OAS preference store is recovered. *)

module Exact_output = Agent_sdk.Exact_output

type evidence_kind =
  | Domain_settlement
  | Scope_retirement
  | Measurement_receipt

type measurement_boundary =
  | Before_measurement_dispatch
  | Measurement_terminal

type recovery_origin =
  | Fresh_start
  | Recovered of { evidence_count : int }

type evidence_decode_error =
  | Invalid_domain_settlement_intent of
      { index : int
      ; cause : Exact_output.domain_settlement_intent_decode_error
      }
  | Invalid_scope_retirement_intent of
      { index : int
      ; cause : Exact_output.flow_preference_retirement_intent_decode_error
      }
  | Invalid_measurement_receipt of
      { index : int
      ; cause : Exact_output.measurement_receipt_snapshot_decode_error
      }
  | Invalid_measurement_transition of
      { index : int
      ; operation_id : string
      ; cause : Exact_output.measurement_receipt_transition_conflict
      }

type journal_decode_error =
  | Journal_malformed_json of string
  | Journal_invalid_fields
  | Journal_unknown_format of string
  | Journal_unsupported_version of int
  | Journal_invalid_field of string
  | Journal_owner_mismatch of string
  | Journal_unknown_evidence_kind of
      { index : int
      ; kind : string
      }
  | Journal_invalid_evidence of evidence_decode_error
  | Journal_integrity_mismatch

type load_error =
  | Invalid_owner_identity of string
  | Journal_read_failed of
      { path : string
      ; detail : string
      }
  | Journal_decode_failed of
      { path : string
      ; cause : journal_decode_error
      }
  | Journal_initialize_failed of
      { path : string
      ; cause : Keeper_fs.durable_write_error
      }
  | Preference_recovery_failed of Exact_output.flow_preference_recovery_error

type commit_error =
  | Evidence_conflict of
      { kind : evidence_kind
      ; evidence_id : string
      }
  | Evidence_write_failed of Keeper_fs.durable_write_error
  | Measurement_transition_rejected of
      { boundary : measurement_boundary
      ; operation_id : string
      ; cause : Exact_output.measurement_receipt_transition_conflict
      }

type t

val recover
  :  base_path:string
  -> keeper_name:string
  -> keeper_generation:string
  -> surface:string
  -> concurrent_scope_budget:int
  -> (t * Exact_output.flow_preference_store * recovery_origin, load_error) result

val path : t -> string
val evidence_count : t -> int

val commit_domain_settlement
  :  t
  -> Exact_output.domain_settlement_intent
  -> (unit, commit_error) result

val commit_scope_retirement
  :  t
  -> Exact_output.flow_preference_retirement_intent
  -> (unit, commit_error) result

val commit_measurement_dispatch_intent
  :  t
  -> Exact_output.measurement_receipt_snapshot
  -> (unit, commit_error) result

val commit_measurement_terminal
  :  t
  -> Exact_output.measurement_receipt_snapshot
  -> (unit, commit_error) result

val load_error_to_string : load_error -> string
val commit_error_to_string : commit_error -> string

module For_testing : sig
  type durable_writer =
    on_durable_commit:(unit -> unit)
    -> ownership_root:string
    -> path:string
    -> bytes:string
    -> (Keeper_fs.durable_commit_outcome, Keeper_fs.durable_write_error) result

  val recover
    :  durable_write:durable_writer
    -> base_path:string
    -> keeper_name:string
    -> keeper_generation:string
    -> surface:string
    -> concurrent_scope_budget:int
    -> (t * Exact_output.flow_preference_store * recovery_origin, load_error) result
end
