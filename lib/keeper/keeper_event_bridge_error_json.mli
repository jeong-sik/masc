(** JSON field builders for OAS agent completion/failure SSE events. *)

val agent_completed_result_fields
  :  (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result
  -> (string * Yojson.Safe.t) list

type agent_failed_error_projection =
  { error : string
  ; error_domain : string
  ; error_code : string
  ; error_retryable : bool
  ; error_detail : Yojson.Safe.t
  }

val agent_failed_error_projection
  :  Agent_sdk.Error.sdk_error
  -> agent_failed_error_projection

val agent_failed_error_fields
  :  Agent_sdk.Error.sdk_error
  -> (string * Yojson.Safe.t) list
