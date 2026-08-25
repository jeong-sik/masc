(** Private immutable exact-output execution plan.

    Admission freezes the provider codec, URL, final application headers,
    serialized body bytes, deadlines, and output contract. Execution receives
    no config or prepared request from which those values could be recomputed. *)

type t
type fingerprint
type preflight

type output_admission_error =
  | Explicit_capability_snapshot_required
  | Unsupported_output_contract of
      { provider_kind : Provider_config.provider_kind
      ; model_id : string
      ; response_format : Types.response_format
      }
  | Unsupported_exact_cross_feature
  | Global_admission_not_allowed
  | Invalid_connect_timeout of float
  | Invalid_body_timeout of float
  | Caller_supplied_header_not_allowed of string
  | Unsupported_image_input
  | Unsupported_document_input
  | Unsupported_audio_input
  | Unsupported_system_prompt
  | Provider_request_rejected of Http_client.http_error
  | Request_body_too_large of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Request_serialization_rejected of Http_client.http_error

type finalization_error =
  | Token_measurement_required of Serving_constraint.t
  | Measured_request_mismatch

type json_validation_provenance =
  | Json_syntax_validated
  | Provider_schema_requested_client_validation_required

type normalized_output =
  | Text_output of string
  | Json_output of
      { value : Yojson.Safe.t
      ; validation : json_validation_provenance
      }

type output_normalization_error =
  | Incomplete_structured_response of Types.stop_reason
  | Missing_structured_text
  | Ambiguous_structured_text of int
  | Unexpected_structured_content
  | Invalid_json of string

(** Run every pure exact-output contract check and freeze the final generation
    request before any provider-native token measurement can dispatch. *)
val preflight
  :  config:Provider_config.t
  -> messages:Types.message list
  -> body_timeout_s:float option
  -> anthropic_thinking_control:Capabilities.anthropic_thinking_control option
  -> (preflight, output_admission_error) result

(** The exact opaque request frozen into [preflight]. Measurement must consume
    this value rather than reconstructing a request. *)
val prepared_request : preflight -> Prepared_completion_request.t

val measurement_request
  :  preflight
  -> ( Exact_output_count_tokens.exact_completion_measurement_request
       , Exact_output_count_tokens.completion_request_error )
       result

val serving_constraint : preflight -> Serving_constraint.t option
val preflight_connect_timeout_s : preflight -> float option
val preflight_body_timeout_s : preflight -> float option
val preflight_request_body_sha256 : preflight -> string
val preflight_request_body_bytes : preflight -> int

val resolve_context_limit
  :  preflight
  -> (int, Prepared_completion_request.fit_error) result

val finalize_unmeasured : preflight -> (t, finalization_error) result

(** Attach token admission only when it belongs to the request owned by this
    preflight. The frozen generation body is never serialized again. *)
val finalize_measured
  :  preflight
  -> Prepared_completion_request.admitted
  -> (t, finalization_error) result

val fingerprint : t -> fingerprint
val fingerprint_to_string : fingerprint -> string
val response_format : t -> Types.response_format
val request_body_sha256 : t -> string
val request_url : t -> string
val request_headers : t -> (string * string) list
val request_body : t -> string
val response_codec : t -> Provider_http_codec.t
val provider_kind : t -> Provider_config.provider_kind
val connect_timeout_s : t -> float option
val body_timeout_s : t -> float option
val verify_frozen_request : t -> bool

val normalize
  :  t
  -> Types.api_response
  -> (normalized_output, output_normalization_error) result
