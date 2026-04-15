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
