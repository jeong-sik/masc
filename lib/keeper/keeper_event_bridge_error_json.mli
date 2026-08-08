(** JSON field builders for OAS agent completion/failure SSE events. *)

val agent_completed_result_fields
  :  (Masc_agent_core.Types.api_response, Masc_agent_core.Error.sdk_error) result
  -> (string * Yojson.Safe.t) list

type agent_failed_error_projection =
  { error : string
  ; error_domain : string
  ; error_code : string
  ; error_retryable : bool
  ; error_detail : Yojson.Safe.t
  }

val agent_failed_error_projection
  :  Masc_agent_core.Error.sdk_error
  -> agent_failed_error_projection

val agent_failed_error_fields
  :  Masc_agent_core.Error.sdk_error
  -> (string * Yojson.Safe.t) list
