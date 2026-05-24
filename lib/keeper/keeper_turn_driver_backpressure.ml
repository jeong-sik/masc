(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/SDK errors into capacity backpressure signals.

    @since God file decomposition *)

open Cascade_internal_error
open Cascade_name

let capacity_backpressure_source_of_http_error = function
  | Llm_provider.Http_client.NetworkError
      { kind = Llm_provider.Http_client.Local_resource_exhaustion; _ } ->
    Some Cascade_slot
  | Llm_provider.Http_client.ProviderFailure
      { kind = Llm_provider.Http_client.Capacity_exhausted _; _ } ->
    Some Provider_capacity
  | Llm_provider.Http_client.HttpError _
  | Llm_provider.Http_client.NetworkError _
  | Llm_provider.Http_client.TimeoutError _
  | Llm_provider.Http_client.AcceptRejected _
  | Llm_provider.Http_client.CliTransportRequired _
  | Llm_provider.Http_client.ProviderTerminal _
  | Llm_provider.Http_client.ProviderFailure _ ->
    None

let capacity_backpressure_of_http_error ?source ~cascade_name last_err =
  match last_err with
  | Some
      (Llm_provider.Http_client.ProviderFailure
         {
           kind =
             Llm_provider.Http_client.Capacity_exhausted
               { retry_after; _ };
           message;
         }) ->
    Some
      (Capacity_backpressure
         {
           cascade_name;
           source =
             Option.value source ~default:Provider_capacity;
           detail = message;
           retry_after_sec = retry_after;
         })
  | Some
      (Llm_provider.Http_client.NetworkError
         {
           kind = Llm_provider.Http_client.Local_resource_exhaustion;
           message;
         }) ->
    Some
      (Capacity_backpressure
         {
           cascade_name;
           source = Option.value source ~default:Cascade_slot;
           detail = message;
           retry_after_sec = None;
         })
  | Some
      (Llm_provider.Http_client.HttpError _
      | Llm_provider.Http_client.NetworkError _
      | Llm_provider.Http_client.TimeoutError _
      | Llm_provider.Http_client.AcceptRejected _
      | Llm_provider.Http_client.CliTransportRequired _
      | Llm_provider.Http_client.ProviderTerminal _
      | Llm_provider.Http_client.ProviderFailure _)
  | None ->
    None

let capacity_backpressure_of_pending ~cascade_name = function
  | Some (source, detail, retry_after_sec) ->
    Some
      (Capacity_backpressure
         {
           cascade_name;
           source;
           detail;
           retry_after_sec;
         })
  | None -> None

let capacity_backpressure_of_sdk_error
    ~cascade_name
    ~message_looks_like_capacity_backpressure
    ~sdk_error_of_masc_internal_error
    sdk_err =
  match sdk_err with
  | Agent_sdk.Error.Provider
      (Llm_provider.Error.CapacityExhausted { retry_after; detail; _ }) ->
    Some
      (sdk_error_of_masc_internal_error
         (Capacity_backpressure
            {
              cascade_name;
              source = Provider_capacity;
              detail;
              retry_after_sec = retry_after;
            }))
  | Agent_sdk.Error.Internal msg
    when message_looks_like_capacity_backpressure msg ->
    Some
      (sdk_error_of_masc_internal_error
         (Capacity_backpressure
            {
              cascade_name;
              source = Provider_capacity;
              detail = msg;
              retry_after_sec = None;
            }))
  | Agent_sdk.Error.Api _
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ ->
    None
