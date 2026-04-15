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
  | Magentic_ledger_v1

type transition_reason =
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

val speech_act_to_string : speech_act -> string
val speech_act_of_string : string -> speech_act option
val delivery_surface_to_string : delivery_surface -> string
val default_delivery_surface_of_speech_act : speech_act -> delivery_surface
val delivery_surface_of_string : string -> delivery_surface option
val model_id_to_string : model_id -> string
val model_id_of_string : string -> model_id option
val default_model_id : model_id
val is_known_social_model : string -> bool
val fallback_social_model : string -> string option
val normalize_social_model : string -> string
val transition_reason_to_string : transition_reason -> string
