open Keeper_types

val apply_to_result :
  meta:keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  Keeper_agent_run.run_result ->
  Keeper_agent_run.run_result * Keeper_social_model_types.social_state

val derive_failure_state :
  meta:keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  Keeper_social_model_types.social_state
