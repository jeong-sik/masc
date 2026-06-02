(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/SDK errors into capacity backpressure signals.

    @since God file decomposition *)

(** Classify an HTTP error into a backpressure source, if applicable. *)
val capacity_backpressure_source_of_http_error :
  Llm_provider.Http_client.http_error ->
  Keeper_internal_error.capacity_backpressure_source option

(** Build a capacity-backpressure internal error from an HTTP error,
    when the error indicates capacity exhaustion. *)
val capacity_backpressure_of_http_error :
  ?source:Keeper_internal_error.capacity_backpressure_source ->
  runtime_id:string ->
  Llm_provider.Http_client.http_error option ->
  Keeper_internal_error.masc_internal_error option

(** Build a capacity-backpressure internal error from a pending
    backpressure triple [(source, detail, retry_after)].  The retry-after
    component carries its provenance ([Explicit] / [Synthetic_default] /
    [No_retry_hint]) so a synthetic default is never read as an explicit
    hint. *)
val capacity_backpressure_of_pending :
  runtime_id:string ->
  (Keeper_internal_error.capacity_backpressure_source * string
   * Keeper_internal_error.capacity_retry_after) option ->
  Keeper_internal_error.masc_internal_error option

(** Classify an SDK error into a capacity-backpressure error,
    when the error indicates provider capacity exhaustion or a
    backpressure-like internal message. *)
val capacity_backpressure_of_sdk_error :
  runtime_id:string ->
  message_looks_like_capacity_backpressure:(string -> bool) ->
  sdk_error_of_masc_internal_error:(Keeper_internal_error.masc_internal_error ->
                                    Agent_sdk.Error.sdk_error) ->
  Agent_sdk.Error.sdk_error ->
  Agent_sdk.Error.sdk_error option
