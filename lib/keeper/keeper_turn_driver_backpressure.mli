(** Capacity backpressure classification helpers for keeper turn execution. *)

val capacity_backpressure_source_of_http_error :
  Llm_provider.Http_client.http_error ->
  Cascade_internal_error.capacity_backpressure_source option

val capacity_backpressure_of_http_error :
  ?source:Cascade_internal_error.capacity_backpressure_source ->
  cascade_name:Cascade_name.t ->
  Llm_provider.Http_client.http_error option ->
  Cascade_internal_error.masc_internal_error option

val capacity_backpressure_of_pending :
  cascade_name:Cascade_name.t ->
  (Cascade_internal_error.capacity_backpressure_source * string * float option) option ->
  Cascade_internal_error.masc_internal_error option

val capacity_backpressure_of_sdk_error :
  cascade_name:Cascade_name.t ->
  message_looks_like_capacity_backpressure:(string -> bool) ->
  sdk_error_of_masc_internal_error:
    (Cascade_internal_error.masc_internal_error -> Agent_sdk.Error.sdk_error) ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error option
