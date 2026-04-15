(** Keeper_social_model — keeper-side social routing for unified turns.

    Converts world observation + raw turn result into a small typed social
    decision so keepers can stay silent, inform, or ask for help without
    relying on repetitive free-form fallback text. *)

type speech_act =
  | Stay_silent
  | Inform
  | Request_help
  | Claim_task
  | Comment_board
  | Post_board
  | Broadcast
  | Defer

type delivery_surface =
  | Silent
  | Visible_reply
  | Board_post
  | Board_comment
  | Task_claim_surface
  | Broadcast_surface

type model_id =
  | Bdi_speech_v1

type social_state = {
  social_model : string;
  belief_summary : string;
  active_desire : string option;
  current_intention : string option;
  blocker : string option;
  need : string option;
  speech_act : speech_act;
  delivery_surface : delivery_surface;
}

type accountability_claim = {
  subject : string;
  task_id : string option;
  evidence_refs : string list;
}

val speech_act_to_string : speech_act -> string
val delivery_surface_to_string : delivery_surface -> string
val model_id_to_string : model_id -> string
val model_id_of_string : string -> model_id option
val normalize_social_model : string -> string
val extract_accountability_claim :
  Keeper_agent_run.run_result -> accountability_claim option

val derive_failure_state :
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  reason:string ->
  social_state

val apply_to_result :
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  Keeper_agent_run.run_result ->
  Keeper_agent_run.run_result * social_state
