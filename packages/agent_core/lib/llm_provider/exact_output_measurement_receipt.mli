(** Private owner of exact-output measurement receipt identity, durable codec,
    and monotonic callback transitions. The public surface is re-exported only
    by [Exact_output]. *)

type measurement_dispatch_fact = Exact_output_flow_admission.measurement_dispatch_fact =
  | No_measurement_dispatch
  | Measurement_dispatch_unknown
  | Measurement_dispatch_started

type measurement_outcome = Exact_output_flow_admission.measurement_outcome =
  | Measurement_not_required
  | Measurement_succeeded
  | Measurement_unsupported
  | Measurement_local_invalid
  | Measurement_transport_failed
  | Measurement_invalid_response
  | Measurement_fence_rejected
  | Measurement_cancelled

type measurement_evidence = Exact_output_flow_admission.measurement_evidence =
  { dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome
  }

type measurement_operation_id = Measurement_operation_id of string

type measurement_receipt_phase = Exact_output_flow_admission.measurement_receipt_phase =
  | Measurement_fence_committed
  | Measurement_wire_started
  | Measurement_terminal

type flow_id = Flow_id of string
type flow_visit_ordinal = Flow_visit_ordinal of int

type measurement_receipt_snapshot =
  { operation_id : measurement_operation_id
  ; flow_id : flow_id
  ; visit_ordinal : flow_visit_ordinal
  ; candidate_id : string
  ; candidate_binding_sha256 : string
  ; catalog_generation_fingerprint : string
  ; catalog_evidence_sha256 : string
  ; request_body_sha256 : string
  ; phase : measurement_receipt_phase
  ; dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome option
  }

type measurement_receipt_snapshot_decode_error =
  | Measurement_receipt_snapshot_malformed_json of string
  | Measurement_receipt_snapshot_invalid_fields
  | Measurement_receipt_snapshot_unknown_format of string
  | Measurement_receipt_snapshot_unsupported_version of int
  | Measurement_receipt_snapshot_invalid_field of string
  | Measurement_receipt_snapshot_integrity_mismatch

type measurement_receipt_transition_conflict =
  | Measurement_operation_mismatch
  | Measurement_operation_binding_mismatch
  | Measurement_invalid_commit_phase of measurement_receipt_phase
  | Measurement_invalid_previous_boundary of
      { phase : measurement_receipt_phase
      ; dispatch : measurement_dispatch_fact
      ; outcome : measurement_outcome option
      }
  | Measurement_phase_regression of
      { previous_phase : measurement_receipt_phase
      ; incoming_phase : measurement_receipt_phase
      }
  | Measurement_evidence_conflict

type measurement_receipt_transition =
  | Measurement_dispatch_intent
  | Measurement_terminal_advance
  | Measurement_idempotent_replay
  | Measurement_transition_conflict of measurement_receipt_transition_conflict

val flow_id_to_string : flow_id -> string
val flow_visit_ordinal_to_int : flow_visit_ordinal -> int
val measurement_operation_id_to_string : measurement_operation_id -> string

val create_measurement_receipt_snapshot
  :  operation_id:string
  -> flow_id:flow_id
  -> visit_ordinal:flow_visit_ordinal
  -> candidate_id:string
  -> candidate_binding_sha256:string
  -> catalog_generation_fingerprint:string
  -> catalog_evidence_sha256:string
  -> request_body_sha256:string
  -> phase:measurement_receipt_phase
  -> dispatch:measurement_dispatch_fact
  -> outcome:measurement_outcome option
  -> measurement_receipt_snapshot

val measurement_receipt_operation_id
  :  measurement_receipt_snapshot
  -> measurement_operation_id

val measurement_receipt_flow_id : measurement_receipt_snapshot -> flow_id
val measurement_receipt_visit_ordinal : measurement_receipt_snapshot -> flow_visit_ordinal
val measurement_receipt_candidate_id : measurement_receipt_snapshot -> string
val measurement_receipt_candidate_binding_sha256 : measurement_receipt_snapshot -> string

val measurement_receipt_catalog_generation_fingerprint
  :  measurement_receipt_snapshot
  -> string

val measurement_receipt_catalog_evidence_sha256 : measurement_receipt_snapshot -> string
val measurement_receipt_request_body_sha256 : measurement_receipt_snapshot -> string
val measurement_receipt_phase : measurement_receipt_snapshot -> measurement_receipt_phase

val measurement_receipt_dispatch_fact
  :  measurement_receipt_snapshot
  -> measurement_dispatch_fact

val measurement_receipt_outcome
  :  measurement_receipt_snapshot
  -> measurement_outcome option

val measurement_receipt_snapshot_to_string : measurement_receipt_snapshot -> string

val measurement_receipt_snapshot_of_string
  :  string
  -> (measurement_receipt_snapshot, measurement_receipt_snapshot_decode_error) result

val measurement_receipt_snapshot_decode_error_to_string
  :  measurement_receipt_snapshot_decode_error
  -> string

val classify_measurement_receipt_transition
  :  previous:measurement_receipt_snapshot option
  -> incoming:measurement_receipt_snapshot
  -> measurement_receipt_transition

val measurement_receipt_same_operation
  :  measurement_receipt_snapshot
  -> measurement_receipt_snapshot
  -> bool
