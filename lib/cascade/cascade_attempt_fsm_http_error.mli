(** Provider-error -> HTTP-error typed mappers for the cascade attempt
    FSM. *)

val provider_capacity_scope_to_http
  :  Llm_provider.Error.capacity_scope
  -> Llm_provider.Http_client.provider_failure_scope

val provider_error_to_http_error
  :  Agent_sdk.Error.provider_error
  -> Llm_provider.Http_client.http_error
