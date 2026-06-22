open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type input = {
  meta : keeper_meta;
  result : Keeper_agent_run.run_result;
  headers : (string * string) list;
  has_text_reply : bool;
}

type state = {
  social_model : string;
  blocker : string option;
  need : string option;
}

type output = {
  speech_act : Keeper_social_model_types.speech_act;
  delivery_surface : Keeper_social_model_types.delivery_surface;
}

val apply_to_result :
  ?turn_ref:Ids.Turn_ref.t ->
  meta:keeper_meta ->
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
