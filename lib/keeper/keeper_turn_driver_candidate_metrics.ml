(** Keeper_turn_driver_candidate_metrics — Candidate health/metrics recording.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Records success, rejection, and error outcomes for cascade candidates
    via the Cascade_health_tracker.

    @since God file decomposition *)

let health_error_kind label =
  Cascade_health_tracker.error_kind_of_string label

let health_keys candidate =
  Cascade_runtime_candidate.health_keys candidate
  |> List.sort_uniq String.compare

let cost_usd_of_response (response : Agent_sdk.Types.api_response) =
  match response.usage with
  | Some usage -> usage.cost_usd
  | None -> None

let positive_finite_float = function
  | value when Float.is_finite value && value > 0.0 -> Some value
  | _ -> None

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
  let error_kind = health_error_kind "accept_rejected" in
  List.iter
    (fun provider_key ->
       Cascade_health_tracker.record_rejected
         Cascade_health_tracker.global
         ~provider_key
         ~error_kind
         ~error_reason:reason
         ())
    (health_keys candidate)
