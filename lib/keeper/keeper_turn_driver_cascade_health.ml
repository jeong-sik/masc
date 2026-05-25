(** Keeper_turn_driver_cascade_health — Health tracking for cascade candidates.

    Extracted from [Keeper_turn_driver.run_named]. Pure functions for
    recording provider health events (success, rejection, error) and
    managing client capacity slots.

    @since God file decomposition *)

open Cascade_error_classify
open Cascade_attempt_fsm

let http_status_of_provider_error = function
  | Some (Provider_error.ServerError { code; _ }) -> Some code
  | Some
      (Provider_error.CapacityBackpressure _
      | Provider_error.RateLimit _
      | Provider_error.AuthError
      | Provider_error.InvalidRequest _
      | Provider_error.CliWrappedHardQuota _
      | Provider_error.CliWrappedMaxTurns _
      | Provider_error.CliWrappedResumableSession _
      | Provider_error.PermissionDenied _
      | Provider_error.ModelNotFound)
  | None -> None

let positive_finite_float = function
  | value when Float.is_finite value && value > 0.0 -> Some value
  | _ -> None

let health_keys candidate =
  Cascade_runtime_candidate.health_keys candidate
  |> List.sort_uniq String.compare

let cost_usd_of_response (response : Agent_sdk.Types.api_response) =
  match response.usage with
  | Some usage -> usage.cost_usd
  | None -> None

let record_candidate_success candidate ~latency_ms
    (result : Cascade_runner.run_result) =
  let latency_ms = positive_finite_float latency_ms in
  let cost_usd = cost_usd_of_response result.response in
  List.iter
    (fun provider_key ->
       Cascade_health_tracker.record_success
         Cascade_health_tracker.global
         ~provider_key
         ?latency_ms
         ?cost_usd
         ())
    (health_keys candidate)

let record_candidate_rejected candidate ~reason =
  let error_kind =
    Cascade_health_tracker.error_kind_of_string "accept_rejected"
  in
  List.iter
    (fun provider_key ->
       Cascade_health_tracker.record_rejected
         Cascade_health_tracker.global
         ~provider_key
         ~error_kind
         ~error_reason:reason
         ())
    (health_keys candidate)

let record_candidate_error candidate (sdk_err : Agent_sdk.Error.sdk_error) =
  let error_reason = Agent_sdk.Error.to_string sdk_err in
  let error_kind =
    Cascade_attempt_fsm.sdk_error_cascade_fallback_class sdk_err
    |> Option.value ~default:"provider_error"
    |> Cascade_health_tracker.error_kind_of_string
  in
  let provider_key = Cascade_runtime_candidate.health_key candidate in
  let model_key = Cascade_runtime_candidate.model_health_key candidate in
  if sdk_error_is_hard_quota sdk_err then
    Cascade_health_tracker.record_hard_quota
      Cascade_health_tracker.global
      ~provider_key
      ~error_kind
      ~error_reason
      ()
  else if sdk_error_is_model_access_denied sdk_err then
    Cascade_health_tracker.record_terminal_failure
      Cascade_health_tracker.global
      ~provider_key:model_key
      ~error_kind
      ~error_reason
      ()
  else if sdk_error_is_required_tool_contract_violation sdk_err then
    Cascade_health_tracker.record_terminal_failure
      Cascade_health_tracker.global
      ~provider_key:model_key
      ~error_kind
      ~error_reason
      ()
  else if sdk_error_is_resumable_cli_session sdk_err
          || sdk_error_is_terminal_provider_runtime_failure sdk_err
  then
    Cascade_health_tracker.record_terminal_failure
      Cascade_health_tracker.global
      ~provider_key
      ~error_kind
      ~error_reason
      ()
  else
    let capacity_source =
      sdk_error_capacity_backpressure_source sdk_err
    in
    let provider_owned_capacity =
      match capacity_source with
      | Some Provider_capacity -> true
      | Some (Client_capacity | Tier_admission | Cascade_slot) -> false
      | None -> true
    in
    if not provider_owned_capacity
    then
      Log.Misc.info
        "cascade_capacity_backpressure: source=%s provider=%s not recorded \
         as provider health/cooldown (error_kind=%s)"
        (capacity_source
         |> Option.map capacity_backpressure_source_to_string
         |> Option.value ~default:"unknown")
        provider_key
        (Cascade_health_tracker.error_kind_to_string error_kind)
    else
      let immediate_cooldown_retry_after =
        match sdk_error_capacity_backpressure_retry_after_s sdk_err with
        | Some retry_after -> Some retry_after
        | None ->
          (match sdk_error_capacity_backpressure_retry_hint sdk_err with
           | Some (Cbr_explicit s) -> Some (Some s)
           | Some (Cbr_synthetic_default s) ->
             Log.Misc.warn
               "cascade_capacity_backpressure: provider=%s retry_after_sec=null \
                injecting synthetic backoff=%.1fs (error_kind=%s)"
               provider_key s
               (Cascade_health_tracker.error_kind_to_string error_kind);
             Some (Some s)
           | None -> sdk_error_soft_rate_limited sdk_err)
      in
      match immediate_cooldown_retry_after with
      | Some retry_after_s ->
        Cascade_health_tracker.record_capacity_backpressure
          Cascade_health_tracker.global
          ~provider_key
          ?retry_after_s
          ~error_kind
          ~error_reason
          ~now:(Unix.time ())
          ()
      | None ->
        Cascade_health_tracker.record_failure
          Cascade_health_tracker.global
          ~provider_key
          ~error_kind
          ~error_reason
          ()

let acquire_client_capacity_slot candidate =
  let capacity_key =
    Cascade_runtime_candidate.capacity_key candidate |> String.trim
  in
  if String.equal capacity_key ""
  then `No_client_capacity
  else
    match Cascade_client_capacity.try_acquire capacity_key with
    | Unregistered -> `No_client_capacity
    | Acquired release -> `Acquired (capacity_key, release)
    | Full { retry_after_s } -> `Full (capacity_key, retry_after_s)
