(** JSON field builders for OAS agent completion/failure SSE events. *)

val agent_completed_result_fields
  :  (Agent_sdk.Types.api_response, Agent_sdk.Error.sdk_error) result
  -> (string * Yojson.Safe.t) list

val agent_failed_error_fields
  :  Agent_sdk.Error.sdk_error
  -> (string * Yojson.Safe.t) list
