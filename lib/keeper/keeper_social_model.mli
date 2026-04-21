(** Keeper_social_model — keeper-side social routing for unified turns.

    Converts world observation + raw turn result into a small typed social
    decision so keepers can stay silent, inform, or ask for help without
    relying on repetitive free-form fallback text. *)

type speech_act = Keeper_social_model_types.speech_act =
  | Stay_silent
  | Inform
  | Request_help
  | Claim_task
  | Comment_board
  | Post_board
  | Broadcast
  | Defer

type delivery_surface = Keeper_social_model_types.delivery_surface =
  | Silent
  | Visible_reply
  | Board_post
  | Board_comment
  | Task_claim_surface
  | Broadcast_surface

type model_id = Keeper_social_model_types.model_id =
  | Bdi_speech_v1
  | Magentic_ledger_v1

type transition_reason = Keeper_social_model_types.transition_reason =
  | Tool_only_stay_silent
  | Tool_only_comment_board
  | Tool_only_post_board
  | Tool_only_broadcast
  | Tool_only_claim_task
  | Tool_only_visible_reply
  | Tool_only_progress_ledger
  | Explicit_social_headers
  | Missing_headers_fallback_visible_reply
  | Invalid_headers_fallback_visible_reply
  | Inferred_visible_reply
  | Protocol_violation_missing_social_headers
  | Protocol_violation_invalid_social_headers
  | Protocol_violation_no_tools_no_social_headers
  | Failure_run_error

type social_state = Keeper_social_model_types.social_state = {
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
val delivery_surface_view_of_meta :
  Keeper_types.keeper_meta -> delivery_surface option
val delivery_surface_view_source_of_meta :
  Keeper_types.keeper_meta -> string option
val model_id_to_string : model_id -> string
val model_id_of_string : string -> model_id option
val is_known_social_model : string -> bool
val fallback_social_model : string -> string option
val normalize_social_model : string -> string
val transition_reason_to_string : transition_reason -> string
val previous_state_of_meta : Keeper_types.keeper_meta -> social_state option
val extract_accountability_claim :
  Keeper_agent_run.run_result -> accountability_claim option

val derive_failure_state :
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  previous_state:social_state option ->
  is_auto_recoverable:bool ->
  reason:string ->
  social_state * transition_reason

val apply_to_result :
  meta:Keeper_types.keeper_meta ->
  observation:Keeper_world_observation.world_observation ->
  previous_state:social_state option ->
  Keeper_agent_run.run_result ->
  Keeper_agent_run.run_result * social_state * transition_reason
