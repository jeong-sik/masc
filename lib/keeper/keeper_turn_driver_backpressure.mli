(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/SDK errors into capacity backpressure signals. *)

open Cascade_internal_error
open Cascade_name

val capacity_backpressure_source_of_http_error :
  Llm_provider.Http_client.error_result -> capacity_backpressure_source option
(** Classify an HTTP error into a backpressure source category. *)

val capacity_backpressure_of_http_error :
  ?source:capacity_backpressure_source ->
  cascade_name:Cascade_name.t ->
  Llm_provider.Http_client.error_result option ->
  masc_internal_error option
(** Build a [Capacity_backpressure] error from an HTTP error result. *)

val capacity_backpressure_of_pending :
  cascade_name:Cascade_name.t ->
  (capacity_backpressure_source * string * float option) option ->
  masc_internal_error option
(** Build a [Capacity_backpressure] error from a pending admission result. *)

val capacity_backpressure_of_sdk_error :
  cascade_name:Cascade_name.t ->
  message_looks_like_capacity_backpressure:(string -> bool) ->
  sdk_error_of_masc_internal_error:(masc_internal_error -> 'a) ->
  Agent_sdk.Error.t ->
  'a option
(** Classify an SDK error as capacity backpressure, mapping through the
    provided error constructor. *)
