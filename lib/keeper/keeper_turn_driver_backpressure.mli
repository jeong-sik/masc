(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/SDK errors into capacity backpressure signals.

    The HTTP error types are polymorphic here — callers match against
    [Llm_provider.Http_client] constructors directly in the .ml. *)

val capacity_backpressure_source_of_http_error :
  'a -> Cascade_internal_error.capacity_backpressure_source option

val capacity_backpressure_of_http_error :
  ?source:Cascade_internal_error.capacity_backpressure_source ->
  cascade_name:Cascade_name.t ->
  'a option ->
  Cascade_internal_error.masc_internal_error option

val capacity_backpressure_of_pending :
  cascade_name:Cascade_name.t ->
  (Cascade_internal_error.capacity_backpressure_source * string * float option) option ->
  Cascade_internal_error.masc_internal_error option

val capacity_backpressure_of_sdk_error :
  cascade_name:Cascade_name.t ->
  message_looks_like_capacity_backpressure:(string -> bool) ->
  sdk_error_of_masc_internal_error:(Cascade_internal_error.masc_internal_error -> 'a) ->
  'b ->
  'a option
