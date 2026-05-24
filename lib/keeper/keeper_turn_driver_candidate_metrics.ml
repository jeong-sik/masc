(** Keeper_turn_driver_candidate_metrics — Candidate health/metrics recording.

    Extracted from [keeper_turn_driver.ml] during godfile decomposition.
    Records success, rejection, and error outcomes for cascade candidates
    via the Cascade_health_tracker.

    @since God file decomposition *)

open Cascade_internal_error

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

let record_candidate_error candidate (sdk_err : Agent_sdk.Error.sdk_error) =
  let error_reason = Agent_sdk.Error.to_string sdk_err in
  let error_kind =
    Cascade_attempt_fsm.sdk_error_cascade_fallback_class sdk_err
    |> Option.value ~default:"provider_error"
    |> health_error_kind
  in
  let provider_key = Cascade_runtime_candidate.health_key candidate in
  let model_key = Cascade_runtime_candidate.model_health_key candidate in
  if Cascade_attempt_fsm.sdk_error_is_hard_quota sdk_err then
    Cascade_health_tracker.record_hard_quota
      Cascade_health_tracker.global
      ~provider_key
      ~error_kind
      ~error_reason
      ()
  else if Cascade_attempt_fsm.sdk_error_is_model_access_denied sdk_err then
    Cascade_health_tracker.record_terminal_failure
      Cascade_health_tracker.global
      ~provider_key:model_key
      ~error_kind
      ~error_reason
      ()
  else if Cascade_attempt_fsm.sdk_error_is_required_tool_contract_violation sdk_err then
    Cascade_health_tracker.record_terminal_failure
      Cascade_health_tracker.global
      ~provider_key:model_key
      ~error_kind
      ~error_reason
      ()
  else if Cascade_attempt_fsm.sdk_error_is_resumable_cli_session sdk_err
          || Cascade_attempt_fsm.sdk_error_is_terminal_provider_runtime_failure sdk_err
  then
    Cascade_health_tracker.record_terminal_failure
      Cascade_health_tracker.global
      ~provider_key
      ~error_kind
      ~error_reason
      ()
  else
    (* Capacity backpressure shares the immediate-cooldown semantics of a
       soft rate limit: one event is sufficient evidence that the
       provider cannot serve, so we call [record_capacity_backpressure]
       rather than counting toward the 3-failure threshold of
       [record_failure]. The retry_after hint, when present, drives
       cooldown duration (clamped by
       [Cascade_health_tracker.soft_rate_limit_max_clamp_sec]).

       D12 root-fix: a MASC-internal [Capacity_backpressure]
       classification with [retry_after_sec = None] previously fell
       through to [record_failure] (3-failure threshold) and the
       cascade rotated immediately onto the same degraded provider
       within milliseconds.  Inject a typed synthetic backoff so the
       cooldown path still applies; emit a warning so operators can
       see that the upstream omitted the hint. *)
    let capacity_source =
      Cascade_attempt_fsm.sdk_error_capacity_backpressure_source sdk_err
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
        match Cascade_attempt_fsm.sdk_error_capacity_backpressure_retry_after_s sdk_err with
        | Some retry_after -> Some retry_after
        | None ->
          (match Cascade_attempt_fsm.sdk_error_capacity_backpressure_retry_hint sdk_err with
           | Some (Cascade_attempt_fsm.Cbr_explicit s) -> Some (Some s)
           | Some (Cascade_attempt_fsm.Cbr_synthetic_default s) ->
             Log.Misc.warn
               "cascade_capacity_backpressure: provider=%s retry_after_sec=null \
                injecting synthetic backoff=%.1fs (error_kind=%s)"
               provider_key s
               (Cascade_health_tracker.error_kind_to_string error_kind);
             Some (Some s)
           | None -> Cascade_attempt_fsm.sdk_error_soft_rate_limited sdk_err)
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
