(** Private measured-admission layer for one frozen exact-output preflight.

    Measurement is a distinct outward effect from generation. It never creates
    an exact generation attempt, call identity, or receipt. *)

type measurement_dispatch_fact =
  | No_measurement_dispatch
  | Measurement_dispatch_unknown
  | Measurement_dispatch_started

type measurement_outcome =
  | Measurement_not_required
  | Measurement_succeeded
  | Measurement_unsupported
  | Measurement_local_invalid
  | Measurement_transport_failed
  | Measurement_invalid_response
  | Measurement_fence_rejected
  | Measurement_cancelled

type measurement_evidence =
  { dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome
  }

type measurement_failure =
  | Unsupported_failure of Input_token_count.error
  | Transport_failure of Http_client.http_error
  | Invalid_response_failure of Input_token_count.error
  | Output_token_resolution_failure of Types.required_output_token_error
  | Invalid_request_failure of string

type measurement_operation_id
type measurement_receipt

type measurement_receipt_phase =
  | Measurement_fence_committed
  | Measurement_wire_started
  | Measurement_terminal

type receipt_snapshot = private
  { operation_id : measurement_operation_id
  ; request_body_sha256 : string
  ; phase : measurement_receipt_phase
  ; dispatch : measurement_dispatch_fact
  ; outcome : measurement_outcome option
  }

type rejection =
  | Serving_evidence_rejected of Serving_constraint.admission_error
  | Context_admission_rejected of Prepared_completion_request.fit_error
  | Measurement_rejected of measurement_failure
  | Plan_finalization_rejected of Exact_output_plan.finalization_error

type 'callback_error outcome =
  | Admitted of
      { plan : Exact_output_plan.t
      ; measurement : measurement_evidence
      }
  | Rejected of
      { cause : rejection
      ; measurement : measurement_evidence
      }
  | Measurement_operation_start_failed of string
  | Measurement_clock_required_for_timeout
  | Before_measurement_dispatch_failed of
      { receipt : measurement_receipt
      ; cause : 'callback_error
      }
  | Measurement_terminal_callback_failed of
      { receipt : measurement_receipt
      ; cause : 'callback_error
      }

val operation_id_to_string : measurement_operation_id -> string
val receipt_snapshot : measurement_receipt -> receipt_snapshot
val receipt_operation_id : receipt_snapshot -> measurement_operation_id
val receipt_request_body_sha256 : receipt_snapshot -> string
val receipt_phase : receipt_snapshot -> measurement_receipt_phase
val receipt_dispatch_fact : receipt_snapshot -> measurement_dispatch_fact
val receipt_outcome : receipt_snapshot -> measurement_outcome option

val admit
  :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> now_unix_s:(unit -> int)
  -> on_measurement_receipt:(measurement_receipt -> unit)
  -> before_measurement_dispatch:(measurement_receipt -> (unit, 'callback_error) result)
  -> on_measurement_terminal:(measurement_receipt -> (unit, 'callback_error) result)
  -> Exact_output_plan.preflight
  -> 'callback_error outcome
