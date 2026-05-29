(** Failure-path metric update for a unified keeper cycle. *)

val update_metrics_from_failure :
  Keeper_meta_contract.keeper_meta ->
  latency_ms:int ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  ?social_state:Keeper_social_model.social_state ->
  ?social_transition_reason:string ->
  ?sdk_error:Agent_sdk.Error.sdk_error ->
  unit ->
  Keeper_meta_contract.keeper_meta
