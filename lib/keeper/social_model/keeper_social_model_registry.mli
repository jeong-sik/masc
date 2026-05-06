open Keeper_types

val apply_to_result :
  meta:keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  previous_state:Keeper_social_model_types.social_state option ->
  Keeper_agent_run.run_result ->
  Keeper_agent_run.run_result
  * Keeper_social_model_types.social_state
  * Keeper_social_model_types.transition_reason

val derive_failure_state :
  meta:keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  previous_state:Keeper_social_model_types.social_state option ->
  is_auto_recoverable:bool ->
  sdk_error:Agent_sdk.Error.sdk_error option ->
  reason:string ->
  Keeper_social_model_types.social_state
  * Keeper_social_model_types.transition_reason
