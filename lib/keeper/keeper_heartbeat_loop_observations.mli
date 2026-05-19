(** Observation reason helpers for the keeper heartbeat loop. *)

type semaphore_wait_observation_kind =
  | Semaphore_wait_pending
  | Semaphore_wait_timeout

val semaphore_wait_observation_reasons
  :  ?phase_label:string
  -> kind:semaphore_wait_observation_kind
  -> channel:Keeper_world_observation.keeper_cycle_channel
  -> unit
  -> string list

val record_semaphore_wait_observation
  :  ?phase_label:string
  -> base_path:string
  -> keeper_name:string
  -> channel:Keeper_world_observation.keeper_cycle_channel
  -> kind:semaphore_wait_observation_kind
  -> unit
  -> unit

type cascade_backpressure_decision =
  | Cascade_admitted
  | Cascade_backpressured of {
      cascade_name : string;
      reason : string;
    }

val cascade_backpressure_observation_reasons : reason:string -> string list

val cascade_backpressure_decision
  :  cascade_resilience:Keeper_exec_preflight.cascade_resilience option
  -> should_run_turn:bool
  -> cascade_name:string
  -> cascade_status:Keeper_health_probe.health_status
  -> cascade_backpressure_decision

val record_cascade_backpressure_observation
  :  base_path:string
  -> keeper_name:string
  -> reason:string
  -> unit

val oas_timeout_budget_observation_reasons : string list

val record_oas_timeout_budget_observation
  :  base_path:string
  -> keeper_name:string
  -> unit

val clear_oas_timeout_budget_failure_reason
  :  base_path:string
  -> keeper_name:string
  -> unit

val prior_oas_timeout_budget_strikes
  :  base_path:string
  -> keeper_name:string
  -> int

val is_oas_timeout_budget_error : Agent_sdk.Error.sdk_error -> bool
val timeout_phase_of_oas_timeout_budget_phase : string -> Keeper_failure_policy.timeout_phase option

val oas_timeout_budget_policy_decision
  :  strikes:int
  -> Agent_sdk.Error.sdk_error
  -> Keeper_failure_policy.decision option

val oas_timeout_budget_metric_outcome : Keeper_failure_policy.decision -> string
