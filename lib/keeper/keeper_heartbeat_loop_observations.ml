(** Observation reason helpers for the keeper heartbeat loop. *)

let provider_timeout_observation_reasons =
  [ "provider_runtime_error"; "provider_timeout"; "keeper_turn_retry_backoff" ]
;;

let record_provider_timeout_observation ~base_path ~keeper_name =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:provider_timeout_observation_reasons;
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let smart_idle_sleep_observation_reasons =
  [ "smart_heartbeat_skip_idle"; "idle_sleep_timeout" ]
;;

let smart_idle_sleep_admission_reasons =
  [ "smart_heartbeat_skip_idle"; "idle_sleep_admitted" ]
;;

let record_smart_idle_sleep_admission ~base_path ~keeper_name =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:smart_idle_sleep_admission_reasons;
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let record_smart_idle_sleep_observation ~base_path ~keeper_name =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:smart_idle_sleep_observation_reasons;
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let clear_provider_timeout_failure_reason ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some
      { Keeper_registry.last_failure_reason =
          Some (Keeper_registry.Provider_timeout_loop _)
      ; _
      } -> Keeper_registry.set_failure_reason ~base_path keeper_name None
  | _ -> ()
;;

type runtime_backpressure_decision =
  | Runtime_admitted
  | Runtime_backpressured of {
      runtime_id : string;
      reason : string;
    }

let skip_reason_component raw =
  let normalized = String.lowercase_ascii (String.trim raw) in
  let mapped =
    String.map
      (function
        | ('a' .. 'z' | '0' .. '9' | '_') as c -> c
        | '-' -> '_'
        | _ -> '_')
      normalized
  in
  if String.equal mapped "" then "unknown" else mapped
;;

let strip_prefix ~prefix value =
  if String.starts_with ~prefix value
  then
    Some
      (String.sub
         value
         (String.length prefix)
         (String.length value - String.length prefix))
  else None
;;

let runtime_backpressure_observation_reasons ~reason =
  let category =
    if String.starts_with ~prefix:"runtime_resilience_" reason
    then "runtime_resilience"
    else if String.starts_with ~prefix:"keeper_health_" reason
    then "keeper_health"
    else "runtime_unhealthy"
  in
  [ "runtime_backpressure"; category; "reason_" ^ skip_reason_component reason ]
;;

let runtime_backpressure_decision
      ~reason_prefix
      ~runtime_resilience
      ~should_run_turn
      ~runtime_id
  =
  match should_run_turn, runtime_resilience with
  | true, Some blocker ->
    Runtime_backpressured
      { runtime_id; reason = reason_prefix ^ "_" ^ blocker }
  | false, _ | true, None -> Runtime_admitted
;;

let record_runtime_backpressure_observation ~base_path ~keeper_name ~reason =
  Keeper_registry.record_skip_reasons
    ~base_path
    keeper_name
    ~reasons:(runtime_backpressure_observation_reasons ~reason);
  Keeper_registry.touch_last_turn_ts ~base_path keeper_name
;;

let prior_provider_timeout_strikes ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name with
  | Some
      { Keeper_registry.last_failure_reason =
          Some (Keeper_registry.Provider_timeout_loop { count })
      ; _
      } -> count
  | _ -> 0
;;

let is_provider_timeout_error (err : Agent_sdk.Error.sdk_error) =
  Keeper_provider_runtime_boundary.is_provider_timeout_error err
;;

let timeout_phase_of_provider_timeout_phase phase =
  let phase = String.trim phase in
  if String.equal phase ""
  then None
  else (
    match Keeper_failure_policy.timeout_phase_of_label phase with
    | Some phase -> Some phase
    | None -> Some Keeper_failure_policy.Unknown_timeout)
;;

let provider_timeout_policy_decision
      ~(strikes : int)
      (err : Agent_sdk.Error.sdk_error)
  : Keeper_failure_policy.decision option
=
  Keeper_provider_runtime_boundary.provider_timeout_policy_decision
    ~strikes
    ~liveness:Keeper_failure_policy.Recent_heartbeat
    err
;;

let provider_timeout_metric_outcome
      (decision : Keeper_failure_policy.decision)
  =
  match decision.lifecycle_effect with
  | Keeper_failure_policy.Keep_running
  | Keeper_failure_policy.Soft_fail_turn -> "warn"
  | Keeper_failure_policy.Pause_current_work -> "soft_backoff"
  | Keeper_failure_policy.Force_release_turn -> "force_release"
  | Keeper_failure_policy.Pause_keeper -> "pause"
  | Keeper_failure_policy.Restart_keeper ->
    if Keeper_failure_policy.should_kill_keeper decision then "promote" else "restart"
;;
