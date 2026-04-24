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

(* #9933: structured error payloads (e.g. [masc_oas_error] JSON, or
   Oas.Error.to_string's "Internal error: [masc_oas_error]" wrapper)
   must NOT be truncated at the narrative budget, or the JSON body is
   cut mid-key and downstream consumers (dashboard, retry classifier,
   log search) see a partial kind=oas_timeout_budget record with the
   budget-underscore value missing, and cannot recover the diagnostic
   fields. The operator ends up re-filing the same triage ticket
   because the budget value, elapsed time, and source field never
   reach them. *)
let masc_oas_error_prefix = "[masc_oas_error]"
let masc_oas_error_wrapped_prefix = "Internal error: " ^ masc_oas_error_prefix

(** Safety cap for structured payloads. ~2000 chars fits a
    Yojson-encoded [masc_internal_error] record of any current variant
    plus the wrapping prefix, with headroom for future fields. Past
    this the payload is pathological and we still cap it rather than
    store unbounded blobs. *)
let masc_oas_error_max_chars = 2000

let truncate_string ~max_chars s =
  String_util.utf8_safe ~max_bytes:(max_chars + 3) ~suffix:"…" s |> String_util.to_string

let truncate_option ~max_chars = function
  | None -> None
  | Some s ->
      Some (String_util.utf8_safe ~max_bytes:(max_chars + 3) ~suffix:"…" s
            |> String_util.to_string)

let has_masc_oas_error_prefix (s : string) : bool =
  let has_prefix prefix =
    let pl = String.length prefix in
    String.length s >= pl && String.sub s 0 pl = prefix
  in
  has_prefix masc_oas_error_prefix
  || has_prefix masc_oas_error_wrapped_prefix

(** [cap_blocker s] returns [s] unchanged when it is a structured
    [masc_oas_error] payload that fits inside [masc_oas_error_max_chars].
    Narrative strings fall through to the normal option-field cap so
    dashboards / logs still see bounded text. This is the #9933 fix
    for budget-underscore truncation. Idempotent. *)
let cap_blocker
    ?(option_max_chars = default_option_field_max_chars)
    (s : string) : string =
  let trimmed = String.trim s in
  let has_prefix = has_masc_oas_error_prefix trimmed in
  if has_prefix && String.length s <= masc_oas_error_max_chars then s
  else if has_prefix then
    truncate_string ~max_chars:masc_oas_error_max_chars s
  else
    truncate_string ~max_chars:option_max_chars s

let cap_blocker_option ?option_max_chars = function
  | None -> None
  | Some s -> Some (cap_blocker ?option_max_chars s)

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
    blocker =
      cap_blocker_option ~option_max_chars state.blocker;
    need = truncate_option ~max_chars:option_max_chars state.need;
  }
