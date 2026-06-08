(** Keeper_turn_driver_backpressure — Capacity backpressure classification.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Pure functions: classify HTTP/SDK errors into capacity backpressure signals.

    @since God file decomposition *)

open Keeper_internal_error

(* Synthetic backoff default for paths where the upstream provides no
   [retry_after] hint.  Carried as [Synthetic_default] so provenance is
   preserved: telemetry shows the value with a synthetic flag rather than a
   laundered explicit hint. *)
let synthetic_retry_after_sec =
  Keeper_binding_health_config.default_capacity_backpressure_backoff_sec

let capacity_backpressure_source_of_http_error = function
  | Llm_provider.Http_client.NetworkError
      { kind = Llm_provider.Http_client.Local_resource_exhaustion; _ } ->
    Some Runtime_slot
  | Llm_provider.Http_client.ProviderFailure
      { kind = Llm_provider.Http_client.Capacity_exhausted _; _ } ->
    Some Provider_capacity
  | Llm_provider.Http_client.HttpError _
  | Llm_provider.Http_client.NetworkError _
  | Llm_provider.Http_client.TimeoutError _
  | Llm_provider.Http_client.AcceptRejected _
  | Llm_provider.Http_client.ProviderTerminal _
  | Llm_provider.Http_client.ProviderFailure _ ->
    None

let capacity_backpressure_of_http_error ?source ?causation_id ?keeper_name
    ?cascade_name ?model_id ~runtime_id last_err
  =
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
           runtime_id;
           source =
             Option.value source ~default:Provider_capacity;
           detail = message;
           retry_after =
             (match retry_after with
              | Some s -> Explicit s
              | None -> Synthetic_default synthetic_retry_after_sec);
           causation_id;
           keeper_name;
           cascade_name;
           model_id;
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
           runtime_id;
           source = Option.value source ~default:Runtime_slot;
           detail = message;
           retry_after = Synthetic_default synthetic_retry_after_sec;
         })
  | Some
      (Llm_provider.Http_client.HttpError _
      | Llm_provider.Http_client.NetworkError _
      | Llm_provider.Http_client.TimeoutError _
      | Llm_provider.Http_client.AcceptRejected _
      | Llm_provider.Http_client.ProviderTerminal _
      | Llm_provider.Http_client.ProviderFailure _)
  | None ->
    None

let capacity_backpressure_of_pending ?causation_id ?keeper_name ?cascade_name
    ?model_id ~runtime_id = function
  | Some (source, detail, retry_after) ->
    Some
      (Capacity_backpressure
         {
           runtime_id;
           source;
           detail;
           retry_after;
           causation_id;
           keeper_name;
           cascade_name;
           model_id;
         })
  | None -> None

let capacity_backpressure_of_sdk_error
    ?causation_id ?keeper_name ?cascade_name ?model_id
    ~runtime_id
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
              runtime_id;
              source = Provider_capacity;
              detail;
              retry_after =
                (match retry_after with
                 | Some s -> Explicit s
                 | None -> Synthetic_default synthetic_retry_after_sec);
              causation_id;
              keeper_name;
              cascade_name;
              model_id;
            }))
  | Agent_sdk.Error.Internal msg
    when message_looks_like_capacity_backpressure msg ->
    Some
      (sdk_error_of_masc_internal_error
         (Capacity_backpressure
            {
              runtime_id;
              source = Provider_capacity;
              detail = msg;
              retry_after = Synthetic_default synthetic_retry_after_sec;
            }))
  | Agent_sdk.Error.Api _
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.Internal _ ->
    None
