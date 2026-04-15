open Keeper_types

type input = {
  meta : keeper_meta;
  observation : Keeper_world_observation.world_observation;
  result : Keeper_agent_run.run_result;
  headers : (string * string) list;
  has_text_reply : bool;
}

type state = {
  social_model : string;
  belief_summary : string;
  active_desire : string option;
  current_intention : string option;
  blocker : string option;
  need : string option;
}

type output = {
  speech_act : Keeper_social_model_types.speech_act;
  delivery_surface : Keeper_social_model_types.delivery_surface;
}

val transition :
  state option ->
  input ->
  state * output * Keeper_social_model_types.transition_reason

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
  reason:string ->
  Keeper_social_model_types.social_state
  * Keeper_social_model_types.transition_reason
