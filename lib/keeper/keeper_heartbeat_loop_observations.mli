(** Observation reason helpers for the keeper heartbeat loop. *)

val provider_timeout_observation_reasons : string list

val record_provider_timeout_observation
  :  base_path:string
  -> keeper_name:string
  -> unit

val smart_idle_sleep_observation_reasons : string list

val smart_idle_sleep_admission_reasons : string list

val record_smart_idle_sleep_admission
  :  base_path:string
  -> keeper_name:string
  -> unit

val record_smart_idle_sleep_observation
  :  base_path:string
  -> keeper_name:string
  -> unit

val clear_provider_timeout_failure_reason
  :  base_path:string
  -> keeper_name:string
  -> unit

type runtime_backpressure_decision =
  | Runtime_admitted
  | Runtime_backpressured of {
      runtime_id : string;
      reason : string;
    }

val runtime_backpressure_observation_reasons : reason:string -> string list

val runtime_backpressure_decision
  :  reason_prefix:string
  -> runtime_resilience:string option
  -> should_run_turn:bool
  -> runtime_id:string
  -> runtime_backpressure_decision

val record_runtime_backpressure_observation
  :  base_path:string
  -> keeper_name:string
  -> reason:string
  -> unit

val prior_provider_timeout_strikes
  :  base_path:string
  -> keeper_name:string
  -> int

val is_provider_timeout_error : Agent_sdk.Error.sdk_error -> bool
val timeout_phase_of_provider_timeout_phase : string -> Keeper_failure_policy.timeout_phase option

val provider_timeout_policy_decision
  :  strikes:int
  -> Agent_sdk.Error.sdk_error
  -> Keeper_failure_policy.decision option

val provider_timeout_metric_outcome : Keeper_failure_policy.decision -> string
