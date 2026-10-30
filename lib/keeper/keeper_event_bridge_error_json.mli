(** JSON field builders for AGENT_CORE agent completion/failure SSE events. *)

val agent_completed_response_fields
  :  Agent_core.Types.api_response
  -> (string * Yojson.Safe.t) list

type agent_failed_error_projection =
  { error : string
  ; error_domain : string
  ; error_code : string
  ; error_retryable : bool
  ; error_detail : Yojson.Safe.t
  }

val agent_failed_error_projection
  :  Agent_core.Error.t
  -> agent_failed_error_projection

val agent_failed_error_fields
  :  Agent_core.Error.t
  -> (string * Yojson.Safe.t) list
