type plan_fingerprint = Exact_output_plan.fingerprint

type output_normalization_error = Exact_output_plan.output_normalization_error =
  | Incomplete_structured_response of Types.stop_reason
  | Missing_structured_text
  | Ambiguous_structured_text of int
  | Unexpected_structured_content
  | Invalid_json of string

type normalized_output = Exact_output_plan.normalized_output =
  | Text_output of string
  | Json_output of
      { value : Yojson.Safe.t
      ; validation : Exact_output_plan.json_validation_provenance
      }

type effect_phase =
  | Before_dispatch
  | Dispatch_started
  | Response_received
  | Terminal

type receipt_identity =
  { fingerprint : plan_fingerprint
  ; request_body_sha256 : string
  }

type response_receipt =
  { identity : receipt_identity
  ; http_status : int
  }

type one_dispatch_receipt =
  | Before_dispatch_receipt of receipt_identity
  | Dispatch_started_receipt of receipt_identity
  | Response_received_receipt of response_receipt
  | Terminal_receipt of response_receipt

type execute_once_error_cause =
  | Clock_required_for_timeout
  | Frozen_request_mismatch
  | Provider_error of Http_client.http_error
  | Output_normalization_failed of output_normalization_error

type pricing_provenance = Pricing_annotation_omitted

type normalized_outcome =
  { receipt : one_dispatch_receipt
  ; response_format : Types.response_format
  ; response : Types.api_response
  ; output : normalized_output
  ; pricing : pricing_provenance
  }

type raw_response_evidence =
  { raw_body : string
  ; raw_body_sha256 : string
  ; response_header_evidence : Http_client.response_header_evidence
  }

type normalized_outcome_with_evidence =
  { outcome : normalized_outcome
  ; raw_response : raw_response_evidence
  }

type execute_once_error_with_evidence =
  { receipt : one_dispatch_receipt
  ; cause : execute_once_error_cause
  ; raw_response : raw_response_evidence option
  }

val receipt_phase : one_dispatch_receipt -> effect_phase
val receipt_dispatch_count : one_dispatch_receipt -> int
val receipt_http_status : one_dispatch_receipt -> int option
val receipt_fingerprint : one_dispatch_receipt -> plan_fingerprint
val receipt_request_body_sha256 : one_dispatch_receipt -> string

val execute_once_with_evidence
  :  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?clock:_ Eio.Time.clock
  -> ?on_phase:(Http_client_phase_observer.phase -> unit)
  -> Exact_output_plan.t
  -> (normalized_outcome_with_evidence, execute_once_error_with_evidence) result
