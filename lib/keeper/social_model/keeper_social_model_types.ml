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

type transition_reason =
  | Tool_only_stay_silent
  | Tool_only_comment_board
  | Tool_only_post_board
  | Tool_only_broadcast
  | Tool_only_claim_task
  | Tool_only_visible_reply
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

let speech_act_to_string = function
  | Stay_silent -> "stay_silent"
  | Inform -> "inform"
  | Request_help -> "request_help"
  | Claim_task -> "claim_task"
  | Comment_board -> "comment_board"
  | Post_board -> "post_board"
  | Broadcast -> "broadcast"
  | Defer -> "defer"

let speech_act_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "stay_silent" -> Some Stay_silent
  | "inform" -> Some Inform
  | "request_help" -> Some Request_help
  | "claim_task" -> Some Claim_task
  | "comment_board" -> Some Comment_board
  | "post_board" -> Some Post_board
  | "broadcast" -> Some Broadcast
  | "defer" -> Some Defer
  | _ -> None

let delivery_surface_to_string = function
  | Silent -> "silent"
  | Visible_reply -> "visible_reply"
  | Board_post -> "board_post"
  | Board_comment -> "board_comment"
  | Task_claim_surface -> "task_claim"
  | Broadcast_surface -> "broadcast"

let default_delivery_surface_of_speech_act = function
  | Stay_silent | Defer -> Silent
  | Inform -> Visible_reply
  | Request_help | Post_board -> Board_post
  | Comment_board -> Board_comment
  | Claim_task -> Task_claim_surface
  | Broadcast -> Broadcast_surface

let delivery_surface_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "silent" -> Some Silent
  | "visible_reply" -> Some Visible_reply
  | "board_post" -> Some Board_post
  | "board_comment" -> Some Board_comment
  | "task_claim" -> Some Task_claim_surface
  | "broadcast" -> Some Broadcast_surface
  | _ -> None

let model_id_to_string = function
  | Bdi_speech_v1 -> "bdi_speech_v1"

let model_id_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "bdi_speech_v1" -> Some Bdi_speech_v1
  | _ -> None

let default_model_id = Bdi_speech_v1

let normalize_social_model value =
  match model_id_of_string value with
  | Some model_id -> model_id_to_string model_id
  | None -> model_id_to_string default_model_id

let transition_reason_to_string = function
  | Tool_only_stay_silent -> "tool_only:stay_silent"
  | Tool_only_comment_board -> "tool_only:comment_board"
  | Tool_only_post_board -> "tool_only:post_board"
  | Tool_only_broadcast -> "tool_only:broadcast"
  | Tool_only_claim_task -> "tool_only:claim_task"
  | Tool_only_visible_reply -> "tool_only:visible_reply"
  | Explicit_social_headers -> "headers:explicit_social_headers"
  | Missing_headers_fallback_visible_reply ->
      "headers_missing:fallback_visible_reply"
  | Invalid_headers_fallback_visible_reply ->
      "headers_invalid:fallback_visible_reply"
  | Inferred_visible_reply -> "text_reply:inferred_visible_reply"
  | Protocol_violation_missing_social_headers ->
      "protocol_violation:missing_social_headers"
  | Protocol_violation_invalid_social_headers ->
      "protocol_violation:invalid_social_headers"
  | Protocol_violation_no_tools_no_social_headers ->
      "protocol_violation:no_tool_calls_and_no_social_headers"
  | Failure_run_error -> "failure:run_error"
