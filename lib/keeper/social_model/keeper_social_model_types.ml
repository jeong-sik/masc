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
  | Magentic_ledger_v1 -> "magentic_ledger_v1"

let model_id_of_string value =
  match String.lowercase_ascii (String.trim value) with
  | "bdi_speech_v1" -> Some Bdi_speech_v1
  | "magentic_ledger_v1" -> Some Magentic_ledger_v1
  | _ -> None

let default_model_id = Bdi_speech_v1

let is_known_social_model value =
  match model_id_of_string value with
  | Some _ -> true
  | None -> false

let fallback_social_model value =
  if is_known_social_model value then None
  else Some (model_id_to_string default_model_id)

let normalize_social_model value =
  match fallback_social_model value with
  | Some fallback -> fallback
  | None ->
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
  | Tool_only_progress_ledger -> "tool_only:progress_ledger"
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

(* Gen8 persistence-layer cap for social_state narrative fields.

   Gen7 (#7676) capped keeper_state_snapshot before continuity_summary
   rendering. The social_state record (belief_summary, active_desire,
   current_intention, blocker, need) follows a parallel accumulation
   path: BDI speech v1 carries these through previous_state into the
   next turn's prompt. Without an explicit bound, a keeper repeating
   "stay_silent" can still grow belief_summary monotonically because
   speech_act=Stay_silent clears response_text but preserves state.

   Same budget discipline as cap_snapshot (400 char primary, 200 char
   option fields) kept as labeled-optional knobs so a cascade-level
   policy can plug different budgets per speech model. *)
let default_belief_summary_max_chars = 400
let default_option_field_max_chars = 200

let truncate_string ~max_chars s =
  if String.length s <= max_chars then s
  else String.sub s 0 max_chars ^ "…"

let truncate_option ~max_chars = function
  | None -> None
  | Some s when String.length s <= max_chars -> Some s
  | Some s -> Some (String.sub s 0 max_chars ^ "…")

let cap_social_state
    ?(belief_max_chars = default_belief_summary_max_chars)
    ?(option_max_chars = default_option_field_max_chars)
    (state : social_state) : social_state =
  {
    state with
    belief_summary =
      truncate_string ~max_chars:belief_max_chars state.belief_summary;
    active_desire =
      truncate_option ~max_chars:option_max_chars state.active_desire;
    current_intention =
      truncate_option ~max_chars:option_max_chars state.current_intention;
    blocker = truncate_option ~max_chars:option_max_chars state.blocker;
    need = truncate_option ~max_chars:option_max_chars state.need;
  }
