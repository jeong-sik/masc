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

type social_state =
  { social_model : string
  ; belief_summary : string
  ; active_desire : string option
  ; current_intention : string option
  ; blocker : string option
  ; need : string option
  ; speech_act : speech_act
  ; delivery_surface : delivery_surface
  }

val speech_act_to_string : speech_act -> string
val speech_act_of_string : string -> speech_act option
val delivery_surface_to_string : delivery_surface -> string
val default_delivery_surface_of_speech_act : speech_act -> delivery_surface
val delivery_surface_of_string : string -> delivery_surface option
val model_id_to_string : model_id -> string
val model_id_of_string : string -> model_id option
val all_model_ids : model_id list
val valid_model_id_strings : string list
val default_model_id : model_id
val is_known_social_model : string -> bool
val fallback_social_model : string -> string option
val normalize_social_model : string -> string
val transition_reason_to_string : transition_reason -> string
val default_belief_summary_max_chars : int
val default_option_field_max_chars : int

(** #9933: safety cap for structured [masc_oas_error] payloads. Larger
    than the narrative cap so JSON bodies survive intact. *)
val masc_oas_error_max_chars : int

(** Prefix the structured-payload branch of {!cap_blocker} matches. *)
val masc_oas_error_prefix : string

(** Truncate a string to [max_chars] characters; append "…" when the
    limit bites. Shared by [cap_social_state] and the checkpoint load
    path so both directions honour the same budget. Idempotent. *)
val truncate_string : max_chars:int -> string -> string

(** [cap_blocker s] preserves structured [masc_oas_error] payloads up
    to {!masc_oas_error_max_chars}, including the
    ["Internal error: [masc_oas_error]"] wrapper emitted by
    [Oas.Error.to_string], so downstream diagnostics (dashboard, retry
    classifier, log search) can read the JSON body intact. Narrative
    strings fall through to {!default_option_field_max_chars}.
    Idempotent. See #9933. *)
val cap_blocker : ?option_max_chars:int -> string -> string

(** Option-aware variant of {!cap_blocker}. *)
val cap_blocker_option : ?option_max_chars:int -> string option -> string option

(** Bound the narrative fields of a [social_state] before it leaves the
    speech model. Caps [belief_summary] and each option field with an
    ellipsis marker when they exceed the budget. The [blocker] field
    is special-cased via {!cap_blocker} so structured
    [masc_oas_error] payloads are preserved intact (#9933).
    Idempotent. *)
val cap_social_state
  :  ?belief_max_chars:int
  -> ?option_max_chars:int
  -> social_state
  -> social_state
